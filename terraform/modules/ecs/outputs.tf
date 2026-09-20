output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "log_group_arn" {
  value = aws_cloudwatch_log_group.app.arn
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}
