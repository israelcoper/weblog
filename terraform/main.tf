provider "aws" {
  region  = var.region
  profile = "terraform"
}

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_caller_identity" "current" {}

# ---------- ECR ----------
resource "aws_ecr_repository" "weblog" {
  name         = "weblog"
  force_delete = true
}

# ---------- Security Groups ----------
resource "aws_security_group" "rds" {
  name   = "weblog-rds-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 5432
    to_port     = 5432
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

resource "aws_security_group" "app" {
  name   = "weblog-app-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port   = 3000
    to_port     = 3000
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

# ---------- RDS ----------
resource "aws_db_instance" "weblog" {
  identifier        = "weblog-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = "weblog_production"
  username = "weblog"
  password = var.db_password

  publicly_accessible    = true
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.rds.id]
}

# ---------- ECS Cluster ----------
resource "aws_ecs_cluster" "weblog" {
  name = "weblog-cluster"
}

# ---------- IAM ----------
resource "aws_iam_role" "ecs_execution" {
  name = "weblog-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------- CloudWatch ----------
resource "aws_cloudwatch_log_group" "weblog" {
  name              = "/ecs/weblog"
  retention_in_days = 7
}

# ---------- Task Definition ----------
resource "aws_ecs_task_definition" "weblog" {
  family                   = "weblog-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution.arn

  container_definitions = jsonencode([{
    name  = "weblog"
    image = "${aws_ecr_repository.weblog.repository_url}:latest"
    portMappings = [{ containerPort = 3000, protocol = "tcp" }]
    environment = [
      { name = "RAILS_ENV",            value = "production" },
      { name = "RAILS_LOG_TO_STDOUT",  value = "true" },
      { name = "DATABASE_URL",         value = "postgres://weblog:${var.db_password}@${aws_db_instance.weblog.address}/weblog_production" },
      { name = "SECRET_KEY_BASE",      value = var.secret_key_base }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.weblog.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ---------- ECS Service ----------
resource "aws_ecs_service" "weblog" {
  name            = "weblog-service"
  cluster         = aws_ecs_cluster.weblog.id
  task_definition = aws_ecs_task_definition.weblog.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true
  }

  depends_on = [aws_db_instance.weblog]
}
