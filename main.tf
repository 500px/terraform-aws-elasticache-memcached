# Define composite variables for resources
module "label" {
  source    = "git::https://github.com/cloudposse/terraform-null-label.git?ref=tags/0.2.1"
  namespace = "${var.namespace}"
  name      = "${var.name}"
  stage     = "${var.stage}"
  tags      = "${var.tags}"
}

resource "null_resource" "host" {
  count = "${var.cluster_size}"

  triggers = {
    name = "${replace(aws_elasticache_cluster.default.cluster_address, ".cfg.", format(".%04d.", count.index + 1))}:11211"
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  name = "cache-${var.label_id == "true" ? module.label.name : local.name}"
}

#
# Security Group Resources
#
resource "aws_security_group" "default" {
  vpc_id = "${var.vpc_id}"
  name   = "${local.name}"

  ingress {
    from_port       = "11211"                    # Memcache
    to_port         = "11211"
    protocol        = "tcp"
    security_groups = ["${var.security_groups}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = "${module.label.tags}"
}

resource "aws_elasticache_subnet_group" "default" {
  name       = "${local.name}"
  subnet_ids = ["${var.subnets}"]
}

resource "aws_elasticache_parameter_group" "default" {
  name   = "${local.name}"
  family = "memcached1.4"

  parameter {
    name  = "max_item_size"
    value = "${var.max_item_size}"
  }
}

#
# ElastiCache Resources
#
resource "aws_elasticache_cluster" "default" {
  cluster_id                   = "${local.name}"
  engine                       = "memcached"
  engine_version               = "${var.engine_version}"
  node_type                    = "${var.instance_type}"
  num_cache_nodes              = "${var.cluster_size}"
  parameter_group_name         = "${aws_elasticache_parameter_group.default.name}"
  subnet_group_name            = "${aws_elasticache_subnet_group.default.name}"
  security_group_ids           = ["${aws_security_group.default.id}"]
  maintenance_window           = "${var.maintenance_window}"
  notification_topic_arn       = "${var.notification_topic_arn}"
  port                         = "11211"
  az_mode                      = "${var.cluster_size == 1 ? "single-az" : "cross-az" }"
  preferred_availability_zones = ["${slice(var.availability_zones, 0, var.cluster_size)}"]
  tags                         = "${module.label.tags}"
}

#
# CloudWatch Resources
#
resource "aws_cloudwatch_metric_alarm" "cache_cpu" {
  alarm_name          = "${local.name}-cpu-utilization"
  alarm_description   = "Memcached cluster CPU utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = "300"
  statistic           = "Average"

  threshold = "${var.alarm_cpu_threshold_percent}"

  dimensions {
    CacheClusterId = "${local.name}"
  }

  alarm_actions = ["${var.alarm_actions}"]
  depends_on    = ["aws_elasticache_cluster.default"]
}

resource "aws_cloudwatch_metric_alarm" "cache_memory" {
  alarm_name          = "${local.name}-freeable-memory"
  alarm_description   = "Memcached cluster freeable memory"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FreeableMemory"
  namespace           = "AWS/ElastiCache"
  period              = "60"
  statistic           = "Average"

  threshold = "${var.alarm_memory_threshold_bytes}"

  dimensions {
    CacheClusterId = "${local.name}"
  }

  alarm_actions = ["${var.alarm_actions}"]
  depends_on    = ["aws_elasticache_cluster.default"]
}

module "dns" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.2.1"
  enabled   = "${var.enabled == "true" && length(var.zone_id) > 0 ? "true" : "false"}"
  namespace = "${var.namespace}"
  name      = "${local.name}"
  stage     = "${var.stage}"
  ttl       = 60
  zone_id   = "${var.zone_id}"
  records   = ["${aws_elasticache_cluster.default.cluster_address}"]
}

module "dns_config" {
  source    = "git::https://github.com/cloudposse/terraform-aws-route53-cluster-hostname.git?ref=tags/0.2.1"
  enabled   = "${var.enabled == "true" && length(var.zone_id) > 0 ? "true" : "false"}"
  namespace = "${var.namespace}"
  name      = "config.${local.name}"
  stage     = "${var.stage}"
  ttl       = 60
  zone_id   = "${var.zone_id}"
  records   = ["${aws_elasticache_cluster.default.configuration_endpoint}"]
}
