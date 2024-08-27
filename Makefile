all: build

build: $(wildcard src/**/*)
	shards build -Dstrict_multi_assign -Dno_number_autocast
release: $(wildcard src/**/*)
	shards build --release
static: $(wildcard src/**/*)
	shards build --release --static
	strip bin/markterm

clean:
	rm -rf bin lib shard.lock

test:
	crystal spec

lint:
	ameba --fix src spec

changelog:
	git cliff -o --sort=newest

.PHONY: clean all test bin lint
