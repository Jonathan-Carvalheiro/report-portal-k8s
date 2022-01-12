APP_NAME := reportportal
NAMESPACE := reportportal

HELM ?= helm

ELASTIC_ADDRESS ?= $(shell aws ssm get-parameter --name /cls/reportportal/elastic/HOST --query 'Parameter.Value' --output text)
POSTGRES_HOST ?= $(shell aws ssm get-parameter --name /cls/reportportal/database/HOST --query 'Parameter.Value' --output text)
POSTGRES_USERNAME ?= $(shell aws ssm get-parameter --name /cls/reportportal/database/USERNAME --query 'Parameter.Value' --output text)
POSTGRES_PASSWORD ?= $(shell aws ssm get-parameter --name /cls/reportportal/database/PASSWORD --query 'Parameter.Value' --output text)
POSTGRES_PORT ?= $(shell aws ssm get-parameter --name /cls/reportportal/database/PORT --query 'Parameter.Value' --output text)
RABBITMQ_PASSWORD ?= $(shell aws ssm get-parameter --name /cls/reportportal/rabbitmq/PASSWORD --query 'Parameter.Value' --output text --with-decryption)


all: create_aws_resources dep_up deploy_rabbitmq deploy_minio deploy_nginx_ingress_controller deploy

create_aws_resources:
	sceptre --dir .aws launch default -y

dep_up:
	$(HELM) repo add elastic https://helm.elastic.co
	$(HELM) repo add stable https://charts.helm.sh/stable
	$(HELM) repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	$(HELM) repo update

deploy_nginx_ingress_controller:
	-kubectl create namespace $(NAMESPACE)
	$(HELM) upgrade --install --namespace $(NAMESPACE) --version 3.7.0 \
		--set controller.ingressClass=nginx-rp \
		--set controller.publishService.enabled=true \
		--set controller.metrics.enabled=true \
		--set controller.metrics.serviceMonitor.enabled=true \
		reportportal-nginx-ingress \
		ingress-nginx/ingress-nginx
	-kubectl label namespace $(NAMESPACE) certmanager.k8s.io/disable-validation="true" --overwrite
	 kubectl apply -f ./certmanager/*.yaml --namespace=$(NAMESPACE)

deploy_rabbitmq:
	-kubectl create ns $(NAMESPACE)
	$(HELM) upgrade --install --namespace $(NAMESPACE) --version 1.46.4 \
		--set forceBoot=true \
		--set rabbitmqPassword=$(RABBITMQ_PASSWORD) \
		--set podManagementPolicy=Parallel \
		--set persistentVolume.enabled=true \
		reportportal-rabbitmq stable/rabbitmq-ha

deploy_minio:
	$(HELM) upgrade --install --namespace $(NAMESPACE)	\
		--version 5.0.33 \
		--set persistence.size=500Gi \
		reportportal-minio stable/minio

deploy:
	mkdir -p target
	$(HELM) ssm -f .aws/helm-values.yml -o target/
	@$(HELM) upgrade --install --namespace $(NAMESPACE) -f target/helm-values.yml \
		--set minio.endpoint=http://reportportal-minio.$(NAMESPACE).svc.cluster.local:9000 \
		--set minio.secretName=reportportal-minio \
		--set elasticsearch.endpoint=$(ELASTIC_ADDRESS):443 \
		--set rabbitmq.SecretName=$(NAMESPACE)-rabbitmq-rabbitmq-ha \
		--set rabbitmq.endpoint.address=reportportal-rabbitmq-rabbitmq-ha.$(NAMESPACE).svc.cluster.local \
		--set rabbitmq.endpoint.user=guest \
		--set rabbitmq.endpoint.apiuser=guest \
		--set postgresql.endpoint.cloudservice=true \
		--set postgresql.endpoint.user=$(POSTGRES_USERNAME) \
		--set postgresql.endpoint.password='$(POSTGRES_PASSWORD)' \
		--set postgresql.endpoint.address=$(POSTGRES_HOST) \
		--set postgresql.endpoint.port=$(POSTGRES_PORT) \
		--recreate-pods \
		reportportal ./reportportal/
