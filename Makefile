.PHONY: all install format lint test gates clean

all: install

install:
	shards install

format:
	crystal tool format src spec

format-check:
	crystal tool format --check src spec

lint:
	ameba src spec

test:
	crystal spec

test-mt:
	crystal spec -Dpreview_mt -Dexecution_context

gates: format-check lint test
	@echo "All gates passed"

clean:
	rm -rf temp/*
	rm -rf .crystal-cache/*
