provider "aws" {
  region = "ap-south-1"
}

# Data sources for AWS account ID and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ECR Repository
resource "aws_ecr_repository" "repo" {
  name                 = "addition-lambda-repo"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "ec2-docker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "ec2-docker-policy"
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-docker-profile"
  role = aws_iam_role.ec2_role.name
}

# VPC for EC2
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# EC2 Security Group
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-sg"
  description = "Allow SSH access"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 Instance to Build and Push Docker Image
resource "aws_instance" "builder" {
  ami           = "ami-0e35ddab05955cf57" # Ubuntu AMI for ap-south-1
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public.id
  security_groups = [aws_security_group.ec2_sg.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
              #!/bin/bash
              set -e
              exec > /var/log/user-data.log 2>&1
              echo "Starting user-data script"
              sudo apt-get update -y
              sudo apt-get install -y docker.io awscli
              sudo systemctl start docker
              sudo systemctl enable docker
              sudo usermod -a -G docker ubuntu
              echo "Copying files"
              echo "${file("lambda_function.py")}" > /home/ubuntu/lambda_function.py
              echo "${file("Dockerfile")}" > /home/ubuntu/Dockerfile
              cd /home/ubuntu
              echo "Logging in to ECR"
              aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.ap-south-1.amazonaws.com
              echo "Building Docker image"
              docker build -t ${aws_ecr_repository.repo.repository_url}:latest .
              echo "Pushing Docker image"
              docker push ${aws_ecr_repository.repo.repository_url}:latest
              echo "Image pushed successfully"
              EOF

  tags = {
    Name = "docker-builder"
  }
}

# Null resource to wait for image to be available
resource "null_resource" "wait_for_image" {
  depends_on = [aws_instance.builder]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command = <<EOT
      $attempt = 1
      while ($attempt -le 60) {
        Write-Host "Checking for image (attempt $attempt)..."
        $tags = aws ecr describe-images --repository-name addition-lambda-repo --region ap-south-1 --query 'imageDetails[*].imageTags' --output text
        if ($tags -like '*latest*') {
          Write-Host "Image found!"
          exit 0
        }
        Start-Sleep -Seconds 10
        $attempt++
      }
      Write-Host "Image not found after 10 minutes"
      exit 1
    EOT
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "lambda-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Lambda Function
resource "aws_lambda_function" "addition_lambda" {
  function_name = "addition-lambda"
  role          = aws_iam_role.lambda_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.repo.repository_url}:latest"
  timeout       = 30
  memory_size   = 128

  depends_on = [null_resource.wait_for_image]
}