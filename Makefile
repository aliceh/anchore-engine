# Project Specific configuration
CI ?= false
COMMIT ?= $(shell echo $${CIRCLE_SHA:=$$(git rev-parse HEAD)}) # Use $CIRCLE_SHA or use SHA from HEAD
GIT_BRANCH ?= $(shell echo $${CIRCLE_BRANCH:=$$(git rev-parse --abbrev-ref HEAD)}) # Use $CIRCLE_BRANCH or branch name from HEAD
CLI_COMMIT ?= $(shell (git ls-remote git@github.com:anchore/anchore-cli "refs/heads/$(GIT_BRANCH)" | awk '{ print $$1 }'))
IMAGE_TAG ?= $(COMMIT)
IMAGE_REPOSITORY ?= anchore/anchore-engine-dev
IMAGE_NAME ?= $(IMAGE_REPOSITORY):$(IMAGE_TAG)
PYTHON_VERSION ?= 3.6.6
VENV_NAME ?= venv

# Make environment configuration
ENV = /usr/bin/env
VENV_ACTIVATE = . $(VENV_NAME)/bin/activate
PYTHON = $(VENV_NAME)/bin/python3
.SHELLFLAGS = -o pipefail -ec # run commands in a -o pipefail -ec flag
.DEFAULT_GOAL := help # Running `Make` will run the help target
.ONESHELL: # Run every line in recipes in same shell - only works on make v3.8.2 or newer (for macos - `brew install gmake && alias make=gmake`)
.NOTPARALLEL: # wait for targets to finish
.EXPORT_ALL_VARIABLES: # send all vars to shell

.PHONY: venv
venv: $(VENV_NAME)/bin/activate ## setup virtual environment
$(VENV_NAME)/bin/activate: setup.py requirements.txt
	if [[ $(CI) == true ]]; then
		hash pip || pip install pip
		hash virtualenv || pip install virtualenv
	else
		hash pip || (echo 'ensure python-pip is installed before attempting to setup virtualenv' && exit 1)
		hash virtualenv || (echo 'ensure virtualenv is installed before attempting to setup virtualenv - `pip install virtualenv`' && exit 1)
	fi
	test -f $(VENV_NAME)/bin/python3 || virtualenv -p python3 $(VENV_NAME)
	pip install --editable .
	touch $(VENV_NAME)/bin/activate

.PHONY: deps
deps: | venv $(VENV_NAME)/.stamps/deps_installed ## install testing dependencies
$(VENV_NAME)/.stamps/deps_installed: $(VENV_NAME)/.stamps
	@
	$(VENV_ACTIVATE)
	hash tox || pip install tox
	hash docker-compose || pip install docker-compose
	hash anchore-cli || pip install anchorecli
	touch $@

.PHONY: build
build: Dockerfile ## build image
	docker build --build-arg ANCHORE_COMMIT=$(COMMIT) --build-arg CLI_COMMIT=$(CLI_COMMIT) -t $(IMAGE_NAME) -f ./Dockerfile .

.PHONY: compose-up
compose-up: $(VENV_NAME)/docker-compose.yaml ## run container with docker-compose.yaml file
$(VENV_NAME)/docker-compose.yaml: docker-compose.yaml deps
	$(VENV_ACTIVATE)
	mkdir -p $(VENV_NAME)/compose/$(COMMIT)
	cp docker-compose.yaml $(VENV_NAME)/compose/$(COMMIT)/docker-compose.yaml
	sed -i "s|anchore/anchore-engine:.*$$|$(IMAGE_NAME)|g" $(VENV_NAME)/compose/$(COMMIT)/docker-compose.yaml
	docker-compose -f $(VENV_NAME)/compose/$(COMMIT)/docker-compose.yaml up -d
	printf '\n%s\n' "To stop anchore-engine use: make compose-down"

.PHONY: compose-down
compose-down:
	$(VENV_ACTIVATE)
	docker-compose -f $(VENV_NAME)/compose/$(COMMIT)/docker-compose.yaml down -v
	rm -rf $(VENV_NAME)/compose/$(COMMIT)

.PHONY: push
push: ## push image to dockerhub
	docker push $(IMAGE_NAME)
	if [[ $(CI) == true ]]; then
		if [[ $(GIT_BRANCH) == 'master' ]]; then
			echo "tagging & pushing image -- docker.io/anchore/anchore-engine:dev"
			docker tag $(IMAGE_NAME) docker.io/anchore/anchore-engine:dev
			docker push docker.io/anchore/anchore-engine:dev
		elif [[ $(GIT_BRANCH) =~ '(0.2|0.3|0.4|0.5|0.6)' ]]; then
			echo "tagging & pushing image -- docker.io/anchore/anchore-engine:$(GIT_BRANCH)-dev"
			docker tag $(IMAGE_NAME) docker.io/anchore/anchore-engine:$(GIT_BRANCH)-dev
			docker push docker.io/anchore/anchore-engine:$(GIT_BRANCH)-dev
		fi
	fi

.PHONY: lint
lint: venv ## lint code with pylint
	$(VENV_ACTIVATE)
	hash pylint || pip install --upgrade pylint
	pylint anchore_engine
	pylint anchore_manager

.PHONY: test-all
test-all: test-unit test-integration test-functional test-compose ## run all tests - unit, integration, functional, e2e

.PHONY: test-unit
test-unit: deps ## run unit tests with tox
	$(VENV_ACTIVATE)
	tox test/unit | tee .tox/tox.log

.PHONY: test-integration
test-integration: deps ## run integration tests with tox
	$(VENV_ACTIVATE)
	if [[ $(CI) == true ]]; then
		tox test/integration | tee .tox/tox.log
	else
		./scripts/tests/test_with_deps.sh test/integration/
	fi

.PHONY: test-functional
test-functional: deps ## run functional tests with tox
	$(VENV_ACTIVATE)
	tox test/functional | tee .tox/tox.log

.PHONY: test-compose
test-compose: compose-up ## run compose tests with docker-compose
	$(VENV_ACTIVATE)
	if [[ $(CI) == true ]]; then
		# forward port 8227 from remote-docker to runner
		ssh -MS anchore -fN4 -L 8228:localhost:8228 remote-docker
	fi
	anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system wait --feedsready ''
	docker-compose logs engine-api
	anchore-cli --u admin --p foobar --url http://localhost:8228/v1 system status
	python scripts/tests/aetest.py docker.io/alpine:latest
	python scripts/tests/aefailtest.py docker.io/alpine:latest
	if [[ ! $(CI) == true ]]; then
		make compose-down
		# close forwarded port
		ssh -S anchore -O exit remote-docker
	fi

.PHONY: clean-all
clean-all: clean clean-tests clean-pyc clean-container ## clean all build/test artifacts

.PHONY: clean
clean-build: ## delete all build directories & virtualenv
	rm -rf venv \
		*.egg-info \
		dist \
		build 

.PHONY: clean-tests
clean-tests: ## delete test dirs
	rm -rf .tox
	rm -f tox.log
	rm -rf .pytest_cache

.PHONY: clean-pyc
clean-pyc: ## deletes all .pyc files
	find . -name '*.pyc' -exec rm -f {} \;

.PHONY: clean-container
clean-container: ## delete built image
	docker rmi $(IMAGE_NAME)

.PHONY: setup-dev
setup-dev: | .python-version ## install pyenv, python and set local .python_version
	@
	echo
	echo 'To enable pyenv in your current shell run: `exec $$SHELL`'
	echo 'Then continue the development environment setup with: `make deps`'
.python-version: | $(HOME)/.pyenv/versions/$(PYTHON_VERSION)/bin/python
	$(HOME)/.pyenv/bin/pyenv local $(PYTHON_VERSION)
$(HOME)/.pyenv/versions/$(PYTHON_VERSION)/bin/python: | $(HOME)/.pyenv
	$(HOME)/.pyenv/bin/pyenv install $(PYTHON_VERSION)
$(HOME)/.pyenv:
	curl https://pyenv.run | $(SHELL)
	echo 'export PATH="$(HOME)/.pyenv/bin:$$PATH"' >> $(HOME)/.bashrc
	echo 'eval "$$(pyenv init -)"' >> $(HOME)/.bashrc
	echo 'eval "$$(pyenv virtualenv-init -)"' >> $(HOME)/.bashrc
	chmod +x $(HOME)/.bashrc
	echo
	echo '# added pyenv config to $(HOME)/.bashrc'
	if [[ -f $(HOME)/.zshrc ]]; then
		echo 'if [ -f ~/.bashrc ]; then source ~/.bashrc; fi' >> $(HOME)/.zshrc
	elif [[ -f $(HOME)/.bash_profile ]]; then
		echo 'if [ -f ~/.bashrc ]; then source ~/.bashrc; fi' >> $(HOME)/.bash_profile
	fi
	echo

$(VENV_NAME)/.stamps:
	@
	mkdir -p $@
	touch $@

.PHONY: help
help: ## show help
	@
	grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
