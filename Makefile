# Coverage is measured over src/, not the root file: pointing kcov at
# src/main.zig alone would only report on the facade.
ZQ_COV_ROOT    := src/main.zig
ZQ_COV_PATTERN := src/
ZQ_COV_MIN     := 0

QUALITY_MK := $(HOME)/tools/zig-quality/quality.mk
ifneq ($(wildcard $(QUALITY_MK)),)
include $(QUALITY_MK)
endif

.PHONY: build test
build:
	zig build

test:
	zig build test
