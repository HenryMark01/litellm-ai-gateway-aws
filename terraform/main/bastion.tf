# ============================================================================
# Windows Bastion Host for Emergency Database Access
# ============================================================================
# This file creates an optional Windows bastion host in the public subnet for
# emergency administrative access to Aurora PostgreSQL and ElastiCache Redis.
#
# The bastion host is disabled by default. Enable it by setting:
#   bastion_enabled = true
#   bastion_allowed_rdp_cidr_blocks = ["your-admin-ip/32"]
#   bastion_key_name = "your-key-pair-name"  (for Administrator password retrieval)
#
# Access Pattern:
#   1. Get password: aws ec2 get-password-data --instance-id <id> --priv-launch-key key.pem
#   2. RDP to bastion: mstsc /v:bastion-ip (use Administrator + decrypted password)
#   3. Open pgAdmin or psql to connect to Aurora
#   4. Open Redis CLI or RedisInsight to connect to ElastiCache
#
# ============================================================================

# --------------------------------------------------------------------------
# Data Sources
# --------------------------------------------------------------------------

# Get latest Windows Server 2022 Core AMI (minimal footprint)
data "aws_ami" "windows_2022_core" {
  count       = var.bastion_enabled ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Core-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# --------------------------------------------------------------------------
# Bastion Security Group
# --------------------------------------------------------------------------
# Allows RDP from authorized admin IPs only

resource "aws_security_group" "bastion" {
  count       = var.bastion_enabled ? 1 : 0
  name        = "${var.tenant}-litellm-${var.environment}-bastion"
  description = "Windows Bastion host security group - RDP from authorized IPs only"
  vpc_id      = module.litellm.vpc_id

  # RDP ingress from authorized admin IPs only
  dynamic "ingress" {
    for_each = length(var.bastion_allowed_rdp_cidr_blocks) > 0 ? [1] : []
    content {
      description = "RDP from authorized admin IPs"
      from_port   = 3389
      to_port     = 3389
      protocol    = "tcp"
      cidr_blocks = var.bastion_allowed_rdp_cidr_blocks
    }
  }

  # Egress to Aurora PostgreSQL (port 5432) via private subnet
  egress {
    description = "PostgreSQL to Aurora in private subnet"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Egress to Redis (port 6379) via private subnet
  egress {
    description = "Redis to ElastiCache in private subnet"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # HTTPS egress for AWS CLI, Windows Update, package downloads
  egress {
    description = "HTTPS for AWS CLI and Windows Update"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP egress for Windows Update
  egress {
    description = "HTTP for Windows Update"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    {
      Name       = "${var.tenant}-litellm-${var.environment}-bastion"
      Component  = "bastion"
      managed-by = "terraform"
    },
    var.additional_tags
  )

  lifecycle {
    create_before_destroy = true
  }
}

# --------------------------------------------------------------------------
# Windows Bastion Host EC2 Instance
# --------------------------------------------------------------------------
# Using t3.micro (1 vCPU, 1 GB RAM) - minimal spec for occasional admin access
# Windows Server Core has smaller footprint than full GUI version

resource "aws_instance" "bastion" {
  count                       = var.bastion_enabled ? 1 : 0
  ami                         = data.aws_ami.windows_2022_core[0].id
  instance_type               = var.bastion_instance_type
  key_name                    = var.bastion_key_name
  vpc_security_group_ids      = [aws_security_group.bastion[0].id]
  subnet_id                   = local.bastion_subnet_id
  associate_public_ip_address = true
  get_password_data           = true

  # Enable IMDSv2 for security
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30 # Minimum for Windows Server
    encrypted             = true
    delete_on_termination = true
  }

  # Install PostgreSQL client and Redis CLI via PowerShell
  user_data = <<-EOF
    <powershell>
    # Install Chocolatey package manager
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    
    # Install PostgreSQL client (psql)
    choco install postgresql16 -y --params '/Password:admin'
    
    # Install Redis CLI
    choco install redis-64 -y
    
    # Install AWS CLI v2
    choco install awscli -y
    
    # Add PostgreSQL bin to PATH
    $env:Path += ";C:\Program Files\PostgreSQL\16\bin"
    [Environment]::SetEnvironmentVariable("Path", $env:Path, [EnvironmentVariableTarget]::Machine)
    </powershell>
  EOF

  tags = merge(
    {
      Name       = "${var.tenant}-litellm-${var.environment}-bastion"
      Component  = "bastion"
      OS         = "Windows Server 2022 Core"
      managed-by = "terraform"
    },
    var.additional_tags
  )

  lifecycle {
    ignore_changes = [ami]
  }
}

# --------------------------------------------------------------------------
# Elastic IP for Bastion (Recommended for stable IP)
# --------------------------------------------------------------------------

resource "aws_eip" "bastion" {
  count    = var.bastion_enabled ? 1 : 0
  instance = aws_instance.bastion[0].id
  domain   = "vpc"

  tags = merge(
    {
      Name       = "${var.tenant}-litellm-${var.environment}-bastion"
      Component  = "bastion"
      managed-by = "terraform"
    },
    var.additional_tags
  )
}

# --------------------------------------------------------------------------
# Local Values for Bastion
# --------------------------------------------------------------------------

locals {
  # Get the first public subnet ID from the module for bastion placement
  bastion_subnet_id = var.bastion_enabled ? data.aws_subnets.public[0].ids[0] : ""
}

# Data source to get public subnets in the VPC
data "aws_subnets" "public" {
  count = var.bastion_enabled ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [module.litellm.vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["*public*"]
  }
}
