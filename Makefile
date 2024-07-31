build: $(wildcard src/**/*)
	shards build -Dstrict_multi_assign -Dno_number_autocast
release: $(wildcard src/**/*)
	shards build --release
static: $(wildcard src/**/*)
	shards build --release --static
	strip bin/markterm
