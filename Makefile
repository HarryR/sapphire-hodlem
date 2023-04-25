DOCKER_RUN=docker run -v `pwd`:/src:rw --rm -ti -u `id -u`:`id -g`
HARDHAT=pnpm hardhat --network sapphire_local
REPO=sapphire-poker
LABEL=harryr
DEVACCT_PUBLIC=0x6052795666b7B062910AaC422b558445F1E4bcC5
DEVACCT_SECRET=0xef2cebd4fe2ed0045f8b12bea2b9a7245d2db5e9d35eb7234f65c15e8facbecc
DOCKER_RUN=docker run -v `pwd`:/src:rw --rm -ti -u `id -u`:`id -g`
DOCKER_RUN_DEV=$(DOCKER_RUN) --network host -w /src -h poker-dev -e HOME=/src -e HISTFILESIZE=0 -e HISTCONTROL=ignoreboth:erasedups -e PRIVATE_KEY=$(DEVACCT_SECRET)
PYTHON=PYTHONPATH=py python3

all:
	@echo ...

tsc:
	pnpm tsc

scores-tree: cache/scores/scores.root

cache/scores/scores.root: $(wildcard py/*.py)
	$(PYTHON) py/genset.py

python:
	$(PYTHON)

sapphire-dev:
	docker run --rm -it -p8545:8545 -p8546:8546 ghcr.io/oasisprotocol/sapphire-dev:local -to $(DEVACCT_PUBLIC)

cache:
	mkdir cache

cache/%.docker: Dockerfile.% cache
	docker build -f $< -t "${REPO}/$*" .
	docker image inspect "${REPO}/$*" > $@

clean:
	rm -rf artifacts cache node_modules typechain-types .bash_history .cache .local lib

.PHONY:
%-shell: cache/%.docker
	$(DOCKER_RUN_DEV) "${REPO}/$*" /bin/bash
