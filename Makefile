ACR          ?= acrknativelab.azurecr.io
PLATFORM     ?= linux/amd64

# -- Demo images -------------------------------------------------------
BACKEND_IMG  := $(ACR)/demo-backend:latest
FRONTEND_IMG := $(ACR)/demo-frontend:latest
JUPYTER_IMG  := $(ACR)/demo-jupyter:latest

# -- Camel-Quarkus (legacy) --------------------------------------------
CAMEL_IMG    := $(ACR)/camel/asb-bridge:latest

.PHONY: help acr-login build-frontend build-backend build-jupyter build-all \
        push-all deploy-demo deploy-integrations deploy-all clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# -- ACR ----------------------------------------------------------------
acr-login: ## Login to Azure Container Registry
	az acr login --name $(shell echo $(ACR) | cut -d. -f1)

# -- Build --------------------------------------------------------------
build-frontend: ## Build frontend (npm build + Docker image)
	cd demo/frontend && npm run build
	docker build --platform $(PLATFORM) -f demo/frontend/Dockerfile -t $(FRONTEND_IMG) .

build-backend: ## Build backend Docker image
	docker build --platform $(PLATFORM) -f demo/backend/Dockerfile -t $(BACKEND_IMG) .

build-jupyter: ## Build Jupyter Docker image
	docker build --platform $(PLATFORM) -f demo/jupyter/Dockerfile -t $(JUPYTER_IMG) .

build-all: build-frontend build-backend build-jupyter ## Build all demo images

# -- Push ---------------------------------------------------------------
push-all: ## Push all demo images to ACR
	docker push $(BACKEND_IMG)
	docker push $(FRONTEND_IMG)
	docker push $(JUPYTER_IMG)

# -- Deploy -------------------------------------------------------------
deploy-demo: ## Deploy demo app (backend + frontend + jupyter + triggers)
	kubectl apply -f demo/k8s/asb-secret.yaml
	kubectl apply -f demo/k8s/backend.yaml
	kubectl apply -f demo/k8s/frontend.yaml
	kubectl apply -f demo/k8s/jupyter.yaml
	kubectl apply -f demo/k8s/trigger.yaml

deploy-integrations: ## Deploy Camel-K integrations (ASB ↔ Broker bridge)
	kubectl apply -f k8s/integrations/asb-to-broker.yaml
	kubectl apply -f k8s/integrations/broker-to-asb.yaml

deploy-all: deploy-demo deploy-integrations ## Deploy everything

# -- Convenience --------------------------------------------------------
redeploy-demo: ## Rollout restart all demo deployments
	kubectl rollout restart deployment/demo-backend deployment/demo-frontend deployment/demo-jupyter

all: acr-login build-all push-all deploy-all ## Full pipeline: login → build → push → deploy

# -- Camel-Quarkus (legacy) --------------------------------------------
build-camel: ## Build Camel-Quarkus app
	cd camel-quarkus && mvn package -DskipTests

package-camel: build-camel ## Build Camel-Quarkus Docker image
	docker build --platform $(PLATFORM) -f camel-quarkus/src/main/docker/Dockerfile.jvm -t $(CAMEL_IMG) camel-quarkus

# -- OAUTHBEARER PoC ----------------------------------------------------
RECEIVER_BASE   := gcr.io/knative-releases/knative-kafka-broker-receiver-loom@sha256:e7d70e601a6bfbe81964793b557ab22d274e898718a3577352b15314266e0192
DISPATCHER_BASE := gcr.io/knative-releases/knative-kafka-broker-dispatcher-loom@sha256:c0c6904f33d767d4c7255781085ebac2fbc72b88dc5f34d3588bb183bb825721
RECEIVER_IMG_OB := $(ACR)/knative-kafka-receiver-oauthbearer:latest
DISPATCHER_IMG_OB := $(ACR)/knative-kafka-dispatcher-oauthbearer:latest

build-conduktor-jar: ## Build Conduktor Azure OAUTHBEARER handler from source
	./oauthbearer-poc/build-conduktor-jar.sh

build-oauthbearer-poc: build-conduktor-jar ## Build derived data-plane images with OAUTHBEARER handler
	docker build --platform $(PLATFORM) \
		--build-arg BASE_IMAGE=$(RECEIVER_BASE) \
		-f oauthbearer-poc/Dockerfile.receiver \
		-t $(RECEIVER_IMG_OB) \
		oauthbearer-poc/
	docker build --platform $(PLATFORM) \
		--build-arg BASE_IMAGE=$(DISPATCHER_BASE) \
		-f oauthbearer-poc/Dockerfile.dispatcher \
		-t $(DISPATCHER_IMG_OB) \
		oauthbearer-poc/

push-oauthbearer-poc: ## Push derived OAUTHBEARER images to ACR
	docker push $(RECEIVER_IMG_OB)
	docker push $(DISPATCHER_IMG_OB)

deploy-oauthbearer-poc: ## Deploy OAUTHBEARER PoC (ConfigMap + patched images)
	./oauthbearer-poc/setup-oauthbearer-poc.sh

oauthbearer-poc: acr-login build-oauthbearer-poc push-oauthbearer-poc deploy-oauthbearer-poc ## Full OAUTHBEARER PoC pipeline

# -- Clean --------------------------------------------------------------
clean: ## Clean build artifacts
	cd camel-quarkus && mvn clean || true
	rm -rf demo/frontend/dist
