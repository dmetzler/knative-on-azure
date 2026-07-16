IMAGE_REGISTRY ?= acrknativelab.azurecr.io
IMAGE_GROUP    ?= camel
IMAGE_NAME     ?= asb-bridge
IMAGE_TAG      ?= latest
IMAGE          := $(IMAGE_REGISTRY)/$(IMAGE_GROUP)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: build package push deploy clean

## Build the Quarkus app (fast JVM mode)
build:
	cd camel-quarkus && mvn package -DskipTests

## Build native binary (requires GraalVM or uses container build)
native:
	cd camel-quarkus && mvn package -Pnative -DskipTests -Dquarkus.native.container-build=true

## Build + container image (JVM)
package: build
	docker build -f camel-quarkus/src/main/docker/Dockerfile.jvm \
		-t $(IMAGE) camel-quarkus

## Build + container image (native — multi-stage, no local GraalVM needed)
package-native:
	docker build -f camel-quarkus/src/main/docker/Dockerfile.native \
		-t $(IMAGE) camel-quarkus

## Push image to ACR
push: package
	docker push $(IMAGE)

## Deploy to K8s (standard Deployment)
deploy:
	kubectl apply -f k8s/camel-quarkus/deployment.yaml

## Full pipeline: build → push → deploy
all: push deploy

## Login to ACR
acr-login:
	az acr login --name $(shell echo $(IMAGE_REGISTRY) | cut -d. -f1)

## Clean build artifacts
clean:
	cd camel-quarkus && mvn clean
