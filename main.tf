# Configure Terraform workspace
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

# Set the region for your resources
data "aws_region" "current" {}

# Define the CIDR block for the VPC
variable "vpc_cidr_block" {
  default = "10.0.0.0/16"
}

# Create a VPC
resource "aws_vpc" "main-1" {
  cidr_block = var.vpc_cidr_block
}

# Create a public subnet within the VPC
resource "aws_subnet" "public-1" {
  vpc_id     = aws_vpc.main-1.id
  cidr_block = "10.0.1.0/24"
  # Enable auto-assign public IP addresses
  map_public_ip_on_launch = true
}

# Create a private subnet in a different Availability Zone
resource "aws_subnet" "private-1" {
  vpc_id     = aws_vpc.main-1.id
  cidr_block = "10.0.2.0/24"

  # Don't enable auto-assign public IP addresses
  map_public_ip_on_launch = false
}

# Create an internet gateway for the VPC
resource "aws_internet_gateway" "gw-1" {
  vpc_id = aws_vpc.main-1.id
}

# Create a route table for the VPC and add a route to the internet gateway
resource "aws_route_table" "main-1" {
  vpc_id = aws_vpc.main-1.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw-1.id
  }
}

# Create a security group for the public subnets
resource "aws_security_group" "public_sg-1" {
  name   = "public_sg-1"
  vpc_id = aws_vpc.main-1.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a security group for the private RDS instance
resource "aws_security_group" "rds_sg-1" {
  name   = "rds_sg-1"
  vpc_id = aws_vpc.main-1.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.public-1.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create a backend machine with a public IP
resource "aws_instance" "backend" {
  ami           = "ami-0914547665e6a707c" # Ubuntu 22.04
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.public_sg-1.id]
  subnet_id              = aws_subnet.public-1.id

  # Configure root volume
  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  # Provisioner to install Docker and Git
  provisioner "remote-exec" {
    inline = [
      "sudo apt update",
      "sudo apt install -y docker.io git",
      "sudo systemctl start docker",
      "sudo systemctl enable docker",
    ]
  }
}

# Create a frontend machine with a public IP
resource "aws_instance" "frontend" {
  ami           = "ami-0914547665e6a707c" # Ubuntu 22.04
  instance_type = "t2.micro"

  vpc_security_group_ids = [aws_security_group.public_sg-1.id]
  subnet_id              = aws_subnet.public-1.id

  # Configure root volume
  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  # Provisioner to install Docker and Git
  provisioner "remote-exec" {
    inline = [
      "sudo apt update",
      "sudo apt install -y docker.io git",
      "sudo systemctl start docker",
      "sudo systemctl enable docker",
    ]
  }
}

# Create a MySQL Community RDS instance in a private subnet (no internet access)
resource "aws_db_instance" "rds" {
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  publicly_accessible    = false # No internet access
  vpc_security_group_ids = [aws_security_group.rds_sg-1.id]
  identifier             = "mydatabase"
  username               = "mydbuser" # username for accessing the MySQL database
  password               = "mydbpassword"
  multi_az               = false


  # Define a subnet group for the RDS instance
  db_subnet_group_name = "mydb_subnet_group"
  tags = {
    Name = "my-rds-instance"
  }
}

# Create a subnet group for the RDS instance
resource "aws_db_subnet_group" "my_rds_subnet_group" {
  name       = "mydb_subnet_group"
  subnet_ids = [aws_subnet.public-1.id, aws_subnet.private-1.id]
}

# CloudWatch metric alarm for CPU utilization on backend instance
resource "aws_cloudwatch_metric_alarm" "backend_cpu_alarm" {
  alarm_name          = "backend-cpu-utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Alarm when CPU utilization exceeds 50% on backend instance"
  alarm_actions       = [var.email_notification_arn] # ARN of SNS topic for email notification
  dimensions = {
    InstanceId = aws_instance.backend.id
  }
}

# CloudWatch metric alarm for CPU utilization on frontend instance
resource "aws_cloudwatch_metric_alarm" "frontend_cpu_alarm" {
  alarm_name          = "frontend-cpu-utilization"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300 # 5 minutes
  statistic           = "Average"
  threshold           = 50
  alarm_description   = "Alarm when CPU utilization exceeds 50% on frontend instance"
  alarm_actions       = [var.email_notification_arn] # ARN of SNS topic for email notification
  dimensions = {
    InstanceId = aws_instance.frontend.id
  }
}

# Email notification SNS topic
resource "aws_sns_topic" "email_notification" {
  name = "cpu-utilization-alerts"
}

# Email subscription for notification
resource "aws_sns_topic_subscription" "email_subscription" {
  topic_arn = aws_sns_topic.email_notification.arn
  protocol  = "email"
  endpoint  = "mahmoud.mody1.mm12@gmail.com" # Replace with your email address
}

# Output the ARN
output "email_notification_arn" {
  value = aws_sns_topic.email_notification.arn
}

# Reference the output in another variable
variable "email_notification_arn" {}

# Output block to expose the public IP
output "backend_public_ip" {
  value = aws_instance.backend.public_ip
}
output "frontend_public_ip" {
  value = aws_instance.frontend.public_ip
}


