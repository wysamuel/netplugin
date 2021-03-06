# BUILD_VERSION will affect archive filenames as well as -version
# default version will be based on $(git describe --tags --always)


.PHONY: all all-CI build clean default unit-test release tar checks go-version gofmt-src \
	golint-src govet-src run-build compile-with-docker

DEFAULT_DOCKER_VERSION := 1.12.6
SHELL := /bin/bash
EXCLUDE_DIRS := bin docs Godeps scripts vagrant vendor install
PKG_DIRS := $(filter-out $(EXCLUDE_DIRS),$(subst /,,$(sort $(dir $(wildcard */)))))
TO_BUILD := ./netplugin/ ./netmaster/ ./netctl/netctl/ ./mgmtfn/k8splugin/contivk8s/ ./mgmtfn/mesosplugin/netcontiv/
HOST_GOBIN := `if [ -n "$$(go env GOBIN)" ]; then go env GOBIN; else dirname $$(which go); fi`
HOST_GOROOT := `go env GOROOT`
NAME := netplugin
VERSION := $(shell scripts/getGitVersion.sh)
TAR_EXT := tar.bz2
NETPLUGIN_CONTAINER_TAG := $(shell ./scripts/getGitVersion.sh)
TAR_FILENAME := $(NAME)-$(VERSION).$(TAR_EXT)
TAR_LOC := .
TAR_FILE := $(TAR_LOC)/$(TAR_FILENAME)
GO_MIN_VERSION := 1.7
GO_MAX_VERSION := 1.8
GO_VERSION := $(shell go version | cut -d' ' -f3 | sed 's/go//')
CI_HOST_TARGETS ?= "host-unit-test host-integ-test host-build-docker-image"
SYSTEM_TESTS_TO_RUN ?= "00SSH|Basic|Network|Policy|TestTrigger|ACIM|Netprofile"
K8S_SYSTEM_TESTS_TO_RUN ?= "00SSH|Basic|Network|Policy"
ACI_GW_IMAGE ?= "contiv/aci-gw:04-12-2017.2.2_1n"

all: build unit-test system-test ubuntu-tests

# 'all-CI' target is used by the scripts/CI.sh that passes appropriate set of
# ENV variables (from the jenkins job) to run OS (centos, ubuntu etc) and
# sandbox specific(vagrant, docker-in-docker)
all-CI: stop clean start
	make ssh-build
	vagrant ssh netplugin-node1 -c 'sudo -i bash -lc "source /etc/profile.d/envvar.sh \
		&& cd /opt/gopath/src/github.com/contiv/netplugin \
		&& make ${CI_HOST_TARGETS}"'
ifdef SKIP_SYSTEM_TEST
	echo "Skipping system tests"
else
	make system-test
endif

test: build unit-test system-test ubuntu-tests

default: build

deps:
	./scripts/deps

godep-save:
	rm -rf vendor Godeps
	godep save ./...

godep-restore:
	godep restore ./...

gofmt-src:
	$(info +++ gofmt $(PKG_DIRS))
	@[[ -z "$$(gofmt -s -d $(PKG_DIRS) | tee /dev/stderr)" ]] || exit 1

# go lint does not automatically recurse
golint-src:
	$(info +++ golint $(PKG_DIRS))
	@for dir in $(PKG_DIRS); do golint -set_exit_status $${dir}/...; done

govet-src:
	$(info +++ govet $(PKG_DIRS))
	@go tool vet $(PKG_DIRS)

misspell-src:
	$(info +++ check spelling $(PKG_DIRS))
	@misspell -locale US -error $(PKG_DIRS)

go-version:
	$(info +++ check go version)
ifneq ($(GO_VERSION), $(lastword $(sort $(GO_VERSION) $(GO_MIN_VERSION))))
	$(error go version check failed, expected >= $(GO_MIN_VERSION), found $(GO_VERSION))
endif
ifneq ($(GO_VERSION), $(firstword $(sort $(GO_VERSION) $(GO_MAX_VERSION))))
	$(error go version check failed, expected <= $(GO_MAX_VERSION), found $(GO_VERSION))
endif

checks: go-version govet-src golint-src gofmt-src misspell-src

# When multi-stage builds are available in VM, source can be copied into
# container FROM the netplugin-build container to simplify this target
checks-with-docker:
	scripts/code_checks_in_docker.sh $(PKG_DIRS)

compile:
	cd $(GOPATH)/src/github.com/contiv/netplugin && \
	NIGHTLY_RELEASE=${NIGHTLY_RELEASE} TO_BUILD="${TO_BUILD}" \
	BUILD_VERSION=$(VERSION) scripts/build.sh

# fully prepares code for pushing to branch, includes building binaries
run-build: deps checks clean compile

compile-with-docker:
	docker build \
		--build-arg NIGHTLY_RELEASE=$(NIGHTLY_RELEASE) \
		--build-arg BUILD_VERSION=$(VERSION) \
		-t netplugin-build:$(NETPLUGIN_CONTAINER_TAG) .

build-docker-image: start
	vagrant ssh netplugin-node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make host-build-docker-image"'

install-shell-completion:
	sudo cp scripts/contrib/completion/bash/netctl /etc/bash_completion.d/netctl

build: start ssh-build stop

clean: deps
	rm -rf $(GOPATH)/pkg/*/github.com/contiv/netplugin/
	go clean -i -v ./...

update:
	vagrant box update


# setting CONTIV_NODES=<number> while calling 'make demo' can be used to bring
# up a cluster of <number> nodes. By default <number> = 1
start:
	CONTIV_DOCKER_VERSION="$${CONTIV_DOCKER_VERSION:-$(DEFAULT_DOCKER_VERSION)}" CONTIV_NODE_OS=${CONTIV_NODE_OS} vagrant up

# ===================================================================
#kubernetes demo targets
k8s-demo:
	cd vagrant/k8s/ && ./copy_demo.sh

k8s-demo-start:
	cd vagrant/k8s/ && ./restart_cluster.sh && vagrant ssh k8master

# ===================================================================
# kubernetes cluster bringup/cleanup targets
k8s-legacy-cluster:
	cd vagrant/k8s/ && ./setup_cluster.sh

k8s-cluster:
	cd vagrant/k8s/ && CONTIV_K8S_USE_KUBEADM=1 ./setup_cluster.sh

k8s-l3-cluster:
	CONTIV_L3=1 make k8s-cluster

k8s-destroy:
	cd vagrant/k8s/ && vagrant destroy -f

k8s-l3-destroy:
	cd vagrant/k8s/ && CONTIV_L3=1 vagrant destroy -f

# ===================================================================
# kubernetes test targets
k8s-legacy-test:
	export CONTIV_K8S_LEGACY=1 && \
	make k8s-sanity-cluster && \
	cd vagrant/k8s/ && vagrant ssh k8master -c 'bash -lc "cd /opt/gopath/src/github.com/contiv/netplugin && make run-build"' && \
	./start_sanity_service.sh
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./createcfg.py -scheduler 'k8s'
	CONTIV_K8S_LEGACY=1 CONTIV_NODES=3 go test -v -timeout 540m ./test/systemtests -check.v -check.abort -check.f "00SSH|TestBasic|TestNetwork|ACID|TestPolicy|TestTrigger"
	cd vagrant/k8s && vagrant destroy -f

k8s-test: k8s-cluster
	cd vagrant/k8s/ && vagrant ssh k8master -c 'bash -lc "cd /opt/gopath/src/github.com/contiv/netplugin && make run-build"'
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./createcfg.py -scheduler 'k8s' -binpath contiv/bin -install_mode 'kubeadm'
	CONTIV_K8S_USE_KUBEADM=1 CONTIV_NODES=3 go test -v -timeout 540m ./test/systemtests -check.v -check.abort -check.f $(K8S_SYSTEM_TESTS_TO_RUN)
	cd vagrant/k8s && vagrant destroy -f

k8s-l3-test: k8s-l3-cluster
	cd vagrant/k8s/ && vagrant ssh k8master -c 'bash -lc "cd /opt/gopath/src/github.com/contiv/netplugin && make run-build"'
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./createcfg.py -scheduler 'k8s' -binpath contiv/bin -install_mode 'kubeadm' -contiv_l3=1
	CONTIV_K8S_USE_KUBEADM=1 CONTIV_NODES=3 go test -v -timeout 540m ./test/systemtests -check.v -check.abort -check.f $(K8S_SYSTEM_TESTS_TO_RUN)
	cd vagrant/k8s && CONTIV_L3=1 vagrant destroy -f
# ===================================================================

# Mesos demo targets
mesos-docker-demo:
	cd vagrant/mesos-docker && \
	vagrant up && \
	vagrant ssh node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make run-build"' && \
	vagrant ssh node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && ./scripts/python/startPlugin.py -nodes 192.168.33.10,192.168.33.11"'

mesos-docker-destroy:
	cd vagrant/mesos-docker && vagrant destroy -f

nomad-docker:
	cd vagrant/nomad-docker && vagrant up
	VAGRANT_CWD=./vagrant/nomad-docker/ vagrant ssh netplugin-node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make host-restart"'

mesos-cni-demo:
	$(MAKE) -C vagrant/mesos-cni $@

mesos-cni-destroy:
	$(MAKE) -C vagrant/mesos-cni $@

demo-ubuntu:
	CONTIV_NODE_OS=ubuntu make demo

stop:
	CONTIV_NODES=$${CONTIV_NODES:-3} vagrant destroy -f

demo: ssh-build
	vagrant ssh netplugin-node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make host-restart host-swarm-restart"'

ssh:
	@vagrant ssh netplugin-node1 -c 'bash -lc "cd /opt/gopath/src/github.com/contiv/netplugin/ && bash"' || echo 'Please run "make demo"'

ssh-build: start
	vagrant ssh netplugin-node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make run-build install-shell-completion"'

unit-test: stop clean
	./scripts/unittests -vagrant

integ-test: stop clean start ssh-build
	vagrant ssh netplugin-node1 -c 'sudo -i bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make host-integ-test"'

ubuntu-tests:
	CONTIV_NODE_OS=ubuntu make clean build unit-test system-test stop

system-test:start
	@echo "system-test: running the following system tests:" $(SYSTEM_TESTS_TO_RUN)
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./createcfg.py
	go test -v -timeout 480m ./test/systemtests -check.v -check.abort -check.f $(SYSTEM_TESTS_TO_RUN)

l3-test:
	CONTIV_L3=2 CONTIV_NODES=3 make stop start ssh-build
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./createcfg.py -contiv_l3 2
	CONTIV_L3=2 CONTIV_NODES=3 go test -v -timeout 900m ./test/systemtests -check.v -check.abort
	CONTIV_L3=2 CONTIV_NODES=3 make stop

#l3-demo setup for docker/swarm
l3-demo: demo
	vagrant ssh netplugin-node1 -c 'netctl global set --fwd-mode routing'

l3bgp-demo:
	CONTIV_L3=1 CONTIV_NODES=3 vagrant up
	make ssh-build
	vagrant ssh netplugin-node1 -c 'sudo -i bash -lc "cd /opt/gopath/src/github.com/contiv/netplugin && make host-restart"'
	vagrant ssh netplugin-node1 -c 'sh /opt/gopath/src/github.com/contiv/netplugin/scripts/l3bgp_demo.sh'

host-build:
	@echo "dev: making binaries..."
	/bin/bash -c 'source /etc/profile.d/envvar.sh; make run-build'

host-unit-test:
	@echo dev: running unit tests...
	cd $(GOPATH)/src/github.com/contiv/netplugin && sudo -E PATH=$(PATH) scripts/unittests

host-unit-test-coverage:
	@echo dev: running unit tests...
	cd $(GOPATH)/src/github.com/contiv/netplugin && sudo -E PATH=$(PATH) scripts/unittests --coverage-basic

host-unit-test-coverage-detail:
	@echo dev: running unit tests...
	cd $(GOPATH)/src/github.com/contiv/netplugin && sudo -E PATH=$(PATH) scripts/unittests --coverage-detail

host-integ-test: host-cleanup start-aci-gw
	@echo dev: running integration tests...
	sudo -E /usr/local/go/bin/go test -v -timeout 20m ./test/integration/ -check.v -encap vlan -fwd-mode bridge
	sudo -E /usr/local/go/bin/go test -v -timeout 20m ./test/integration/ -check.v -encap vxlan -fwd-mode bridge
	sudo -E /usr/local/go/bin/go test -v -timeout 20m ./test/integration/ -check.v -encap vxlan -fwd-mode routing
	sudo -E /usr/local/go/bin/go test -v -timeout 20m ./test/integration/ -check.v -check.f "AppProfile" -encap vlan -fwd-mode bridge --fabric-mode aci

start-aci-gw:
	@echo dev: starting aci gw...
	docker pull $(ACI_GW_IMAGE)
	docker run --net=host -itd -e "APIC_URL=SANITY" -e "APIC_USERNAME=IGNORE" -e "APIC_PASSWORD=IGNORE" --name=contiv-aci-gw $(ACI_GW_IMAGE)

host-build-docker-image:
	./scripts/netContain/build_image.sh

host-cleanup:
	@echo dev: cleaning up services...
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./cleanup.py -nodes ${CLUSTER_NODE_IPS}

host-swarm-restart:
	@echo dev: restarting swarm ...
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./startSwarm.py -nodes ${CLUSTER_NODE_IPS} -swarm ${CONTIV_DOCKER_SWARM}

host-restart:
	@echo dev: restarting services...
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./startPlugin.py -nodes ${CLUSTER_NODE_IPS}

# create the rootfs for v2plugin. this is required for docker plugin create command
host-pluginfs-create:
	@echo dev: creating a docker v2plugin rootfs ...
	sh scripts/v2plugin_rootfs.sh

# if rootfs already exists, copy newly compiled contiv binaries and start plugin on local host
host-plugin-update:
	@echo dev: updating docker v2plugin ...
	docker plugin disable ${CONTIV_V2PLUGIN_NAME}
	docker plugin rm -f ${CONTIV_V2PLUGIN_NAME}
	cp bin/netplugin bin/netmaster bin/netctl install/v2plugin/rootfs
	docker plugin create ${CONTIV_V2PLUGIN_NAME} install/v2plugin
	docker plugin enable ${CONTIV_V2PLUGIN_NAME}

# cleanup all containers, plugins and start the v2plugin on all hosts
host-plugin-restart:
	@echo dev: restarting services...
	cp bin/netplugin bin/netmaster bin/netctl install/v2plugin/rootfs
	cd $(GOPATH)/src/github.com/contiv/netplugin/scripts/python && PYTHONIOENCODING=utf-8 ./startPlugin.py -nodes ${CLUSTER_NODE_IPS} -plugintype "v2plugin"

# complete workflow to create rootfs, create/enable plugin and start swarm-mode
demo-v2plugin:
	CONTIV_V2PLUGIN_NAME="$${CONTIV_V2PLUGIN_NAME:-contiv/v2plugin:0.1}" CONTIV_DOCKER_VERSION="$${CONTIV_DOCKER_VERSION:-1.13.1}" CONTIV_DOCKER_SWARM="$${CONTIV_DOCKER_SWARM:-swarm_mode}" make ssh-build
	vagrant ssh netplugin-node1 -c 'bash -lc "source /etc/profile.d/envvar.sh && cd /opt/gopath/src/github.com/contiv/netplugin && make host-pluginfs-create host-plugin-restart host-swarm-restart"'

# release a v2 plugin
host-plugin-release:
	@echo dev: creating a docker v2plugin ...
	sh scripts/v2plugin_rootfs.sh
	docker plugin create ${CONTIV_V2PLUGIN_NAME} install/v2plugin
	@echo dev: pushing ${CONTIV_V2PLUGIN_NAME} to docker hub
	@echo dev: need docker login with user in contiv org
	docker plugin push ${CONTIV_V2PLUGIN_NAME}

##########################
## Packaging and Releasing
##########################

# build tarball
tar: compile-with-docker
	docker rm netplugin-build || :
	c_id=$$(docker create --name netplugin-build netplugin-build:$(NETPLUGIN_CONTAINER_TAG)) && \
	for f in netplugin netmaster netctl contivk8s netcontiv; do \
		docker cp $${c_id}:/go/bin/$$f bin/$$f; done && \
	docker rm $${c_id}
	tar -jcf $(TAR_FILE) \
		-C bin netplugin netmaster netctl contivk8s netcontiv \
		-C ../scripts contrib/completion/bash/netctl get-contiv-diags

clean-tar:
	@rm -f $(TAR_LOC)/*.$(TAR_EXT)

# do not run directly, use "release" target
release-built-version: tar
	TAR_FILENAME=$(TAR_FILENAME) TAR_FILE=$(TAR_FILE) OLD_VERSION=${OLD_VERSION} \
	NIGHTLY_RELEASE=${NIGHTLY_RELEASE} scripts/release.sh
	@make clean-tar

# The first "release" below is not a target, it is a "target-specific variable"
#   and sets (and in this case exports) a variable to the target's environment
# The second release runs make as a subshell but with BUILD_VERSION set
# to write the correct version for assets everywhere
#
# GITHUB_USER and GITHUB_TOKEN are needed be set (used by github-release)
release: export BUILD_VERSION=$(shell cat version/CURRENT_VERSION)
release:
	@make release-built-version
