DOCKER_RUN=docker run -v `pwd`:/src:rw --rm -ti -u `id -u`:`id -g`
HARDHAT=pnpm hardhat --network sapphire_local
REPO=sapphire-poker
LABEL=harryr
DOCKER_RUN=docker run -v `pwd`:/src:rw --rm -ti -u `id -u`:`id -g`
DOCKER_RUN_DEV=$(DOCKER_RUN) --network host -w /src -h poker-dev -e HOME=/src -e HISTFILESIZE=0 -e HISTCONTROL=ignoreboth:erasedups
PYTHON=PYTHONPATH=py python3

all:
	@echo ...

tsc:
	$(DOCKER_RUN_DEV) pnpm tsc

hardhat-compile:
	$(DOCKER_RUN_DEV) pnpm hardhat compile

hardhat-test:
	$(DOCKER_RUN_DEV) pnpm hardhat test

hardhat-coverage:
	$(DOCKER_RUN_DEV) pnpm hardhat coverage

pnpm-install:
	$(DOCKER_RUN_DEV) pnpm install

scores-tree: cache/scores/scores.root

cache/scores/scores.root: $(wildcard py/*.py)
	$(PYTHON) py/genset.py

python:
	$(PYTHON)

py/genset.exe: py/genset.c
	$(CC) -o $@ -Wall -Wextra -O3  -march=native $<

SAPPHIRE_DEV_DOCKER=ghcr.io/oasisprotocol/sapphire-dev:local
#SAPPHIRE_DEV_DOCKER=ghcr.io/oasisprotocol/sapphire-dev:latest

sapphire-dev:
	docker run --rm -it -p8545:8545 -p8546:8546 $(SAPPHIRE_DEV_DOCKER) -to 'test test test test test test test test test test test junk' -n 20

cache:
	mkdir cache

cache/%.docker: Dockerfile.% cache
	if [ ! -f "$@" ]; then \
		docker build -f $< -t "${REPO}/$*" . ; \
		docker image inspect "${REPO}/$*" > $@ ; \
	fi

clean:
	rm -rf artifacts cache coverage lib node_modules typechain-types
	rm -rf .cache .config .local .npm
	rm -rf .bash_history .node_repl_history .ts_node_repl_history coverage.json pnpm-lock.yaml

%-shell: cache/%.docker
	$(DOCKER_RUN_DEV) "${REPO}/$*" /bin/bash
