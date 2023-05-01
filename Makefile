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
	pnpm tsc

hardhat-test:
	pnpm hardhat test

hardhat-coverage:
	pnpm hardhat coverage

scores-tree: cache/scores/scores.root

cache/scores/scores.root: $(wildcard py/*.py)
	$(PYTHON) py/genset.py

python:
	$(PYTHON)

SAPPHIRE_DEV_DOCKER=ghcr.io/oasisprotocol/sapphire-dev:local
#SAPPHIRE_DEV_DOCKER=ghcr.io/oasisprotocol/sapphire-dev:latest

sapphire-dev:
	docker run --rm -it -p8545:8545 -p8546:8546 $(SAPPHIRE_DEV_DOCKER) -to 'test test test test test test test test test test test junk' -n 20

cache:
	mkdir cache

cache/%.docker: Dockerfile.% cache
	docker build -f $< -t "${REPO}/$*" .
	docker image inspect "${REPO}/$*" > $@

clean:
	rm -rf artifacts cache node_modules typechain-types .bash_history .cache .local lib coverage coverage.json

.PHONY:
%-shell: cache/%.docker
	$(DOCKER_RUN_DEV) "${REPO}/$*" /bin/bash
