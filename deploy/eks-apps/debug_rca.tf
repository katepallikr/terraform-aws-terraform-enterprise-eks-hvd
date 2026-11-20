# --- TEMP RCA (network): read-only. Delete after diagnosis. ---

data "aws_lb" "tfe" {
  tags = { "service.k8s.aws/stack" = "tfe/terraform-enterprise" }
}

data "aws_lb_target_group" "tfe" {
  tags = { "service.k8s.aws/stack" = "tfe/terraform-enterprise" }
}

data "aws_security_groups" "node" {
  filter {
    name   = "group-name"
    values = ["sandbox-tfe-eks-nodegroup-allow"]
  }
}

data "aws_vpc_security_group_rules" "lb" {
  filter {
    name   = "group-id"
    values = data.aws_lb.tfe.security_groups
  }
}

data "aws_vpc_security_group_rule" "lb" {
  for_each               = toset(data.aws_vpc_security_group_rules.lb.ids)
  security_group_rule_id = each.value
}

data "aws_vpc_security_group_rules" "node" {
  filter {
    name   = "group-id"
    values = data.aws_security_groups.node.ids
  }
}

data "aws_vpc_security_group_rule" "node" {
  for_each               = toset(data.aws_vpc_security_group_rules.node.ids)
  security_group_rule_id = each.value
}

data "kubernetes_resources" "rca_endpoints" {
  api_version    = "discovery.k8s.io/v1"
  kind           = "EndpointSlice"
  namespace      = "tfe"
  label_selector = "kubernetes.io/service-name=terraform-enterprise"
}

output "net_1_nlb" {
  value = {
    scheme     = data.aws_lb.tfe.internal ? "internal" : "internet-facing"
    dns        = data.aws_lb.tfe.dns_name
    subnets    = data.aws_lb.tfe.subnets
    sgs        = data.aws_lb.tfe.security_groups
    cross_zone = data.aws_lb.tfe.enable_cross_zone_load_balancing
  }
}

output "net_2_target_group" {
  value = {
    port        = data.aws_lb_target_group.tfe.port
    protocol    = data.aws_lb_target_group.tfe.protocol
    target_type = data.aws_lb_target_group.tfe.target_type
    hc          = data.aws_lb_target_group.tfe.health_check
  }
}

output "net_3_lb_sg_rules" {
  value = [for r in data.aws_vpc_security_group_rule.lb :
    "${r.is_egress ? "EGRESS" : "INGRESS"} ${r.ip_protocol} ${r.from_port}-${r.to_port} from ${coalesce(r.cidr_ipv4, r.referenced_security_group_id, "?")}"]
}

output "net_4_node_sg_rules" {
  value = [for r in data.aws_vpc_security_group_rule.node :
    "${r.is_egress ? "EGRESS" : "INGRESS"} ${r.ip_protocol} ${r.from_port}-${r.to_port} from ${coalesce(r.cidr_ipv4, r.referenced_security_group_id, "?")}"]
}

output "net_5_endpoints" {
  value = [for s in data.kubernetes_resources.rca_endpoints.objects : [
    for ep in try(s.endpoints, []) : "${join(",", ep.addresses)} ready=${try(ep.conditions.ready, "?")} zone=${try(ep.zone, "?")}"
  ]]
}
