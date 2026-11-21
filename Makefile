# Run from the acm-deploy-load repository root with: make -f /path/to/this/Makefile <target>
# Playbook targets run the playbooks only. Render the matching vars file first.

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# System configuration
# ---------------------------------------------------------------------------
SHELL := /bin/bash
# Avoid issues with python venv PATH hijacking
YQ_BIN ?= /usr/bin/yq

# ---------------------------------------------------------------------------
# Inventory
# Point to the right inventory file, e.g. ansible/inventory/cloudXXX.local.
# Any target accepts: make <target> INV_FILE=/path/to/local/file
# ---------------------------------------------------------------------------
INV_DIR ?= ./ansible/inventory
# Tolerate a trailing slash in an override so paths in messages stay clean.
_INV_DIR := $(patsubst %/,%,$(INV_DIR))
INV_FILES = $(wildcard $(_INV_DIR)/*.local)
INV_FILE ?= $(if $(filter 1,$(words $(INV_FILES))),$(INV_FILES))

# ---------------------------------------------------------------------------
# YQ file
# ---------------------------------------------------------------------------
YQ_DIR ?= .
_YQ_DIR := $(patsubst %/,%,$(YQ_DIR))
YQ_FILE ?= $(_YQ_DIR)/all.yq

VARS_DIR ?= ./ansible/vars
_VARS_DIR := $(patsubst %/,%,$(VARS_DIR))

# ---------------------------------------------------------------------------
# Every target here is phony: none of them produce a file of their own name,
# and the checks must run even if a file happens to share a target name.
# ---------------------------------------------------------------------------
.PHONY: help \
	check-tools check-inventory \
	check-all-vars check-telco-core-vars \
	render-all render-telco-core render-everything step0-render-vars \
	sno-manifests step1.1-sno-manifests \
	rhacm-ztp-setup step2-rhacm-ztp-setup \
	telco-core-manifests step1.2-telco-core-manifests \
	rhacm-deploy step3-rhacm-deploy \
	ibu-prepare-seed-cluster step4-ibu-prepare-seed-cluster \
	ibi-prepare-snos step5-ibi-prepare-snos \
	ibi-replace-disks step6-ibi-replace-disks \
	sno-ai-setup sno-ibi-setup ibu-seed-image

# Ordered flows: their steps must not overlap under make -j.
# (GNU make >= 4.4 honours the prerequisite list; older make serialises everything.)
.NOTPARALLEL: sno-ai-setup sno-ibi-setup ibu-seed-image

# ---------------------------------------------------------------------------
# Validation targets
# ---------------------------------------------------------------------------
check-tools:
	@command -v "$(YQ_BIN)" > /dev/null 2>&1 || { echo "Error: yq not found: $(YQ_BIN). Install it or set YQ_BIN=<path>." >&2; exit 1; }

check-inventory:
	@if [ -z "$(INV_FILE)" ]; then \
		if [ $(words $(INV_FILES)) -eq 0 ]; then \
			echo "Error: No .local files found in $(_INV_DIR)" >&2; exit 1; \
		else \
			echo "Error: Multiple .local files found in $(_INV_DIR): $(INV_FILES). Specify one via INV_FILE=<file>" >&2; exit 1; \
		fi; \
	elif [ ! -f "$(INV_FILE)" ]; then \
		echo "Error: Specified inventory file '$(INV_FILE)' does not exist. Set INV_FILE=<file>." >&2; exit 1; \
	fi

# $(1): vars file basename; $(2): command that prepares it.
define check-vars-file
	@test -s "$(_VARS_DIR)/$(1).yml" || { echo "Error: Missing or empty $(_VARS_DIR)/$(1).yml. Run $(2)." >&2; exit 1; }
	@"$(YQ_BIN)" -e 'tag == "!!map"' "$(_VARS_DIR)/$(1).yml" > /dev/null || { echo "Error: $(_VARS_DIR)/$(1).yml must contain a YAML mapping. Run $(2)." >&2; exit 1; }
endef

check-all-vars: check-tools
	$(call check-vars-file,all,make render-all)

check-telco-core-vars: check-tools
	$(call check-vars-file,telco-core,make render-telco-core)

# ---------------------------------------------------------------------------
# VARs rendering targets
# ---------------------------------------------------------------------------
render-all: check-tools
	@"$(YQ_BIN)" '. *= (load("$(YQ_FILE)").all // {})' "$(_VARS_DIR)/all.sample.yml" > "$(_VARS_DIR)/all.yml"

# telco-core profile; rendered on demand
render-telco-core: check-tools
	@"$(YQ_BIN)" '. *?= (load("$(YQ_FILE)").all // {}) | . *= (load("$(YQ_FILE)").telco-core // {})' "$(_VARS_DIR)/telco-core.sample.yml" > "$(_VARS_DIR)/telco-core.yml"

render-everything: check-tools render-all render-telco-core

step0-render-vars: check-tools render-all

# ---------------------------------------------------------------------------
# Playbook targets
# ---------------------------------------------------------------------------
sno-manifests: step1.1-sno-manifests
step1.1-sno-manifests: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/sno-manifests.yml)

telco-core-manifests: step1.2-telco-core-manifests
step1.2-telco-core-manifests: check-inventory check-all-vars check-telco-core-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/telco-core-manifests.yml)

rhacm-ztp-setup: step2-rhacm-ztp-setup
step2-rhacm-ztp-setup: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/rhacm-ztp-setup.yml)

rhacm-deploy: step3-rhacm-deploy
step3-rhacm-deploy: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/rhacm-deploy.yml)

ibu-prepare-seed-cluster: step4-ibu-prepare-seed-cluster
step4-ibu-prepare-seed-cluster: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/ibu-prepare-seed-cluster.yml)

ibi-prepare-snos: step5-ibi-prepare-snos
step5-ibi-prepare-snos: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/ibi-prepare-snos.yml --forks 50 \
		-e '{"ibi_prepare_disk_file": true, "ibi_hv_copy_disk_file": true, "ibi_replace_sno_disk_file": false}')

ibi-replace-disks: step6-ibi-replace-disks
step6-ibi-replace-disks: check-inventory check-all-vars
	(time ansible-playbook -i "$(INV_FILE)" ansible/ibi-prepare-snos.yml --forks 50 \
		-e '{"ibi_prepare_disk_file": false, "ibi_hv_copy_disk_file": false, "ibi_replace_sno_disk_file": true}')

# ---------------------------------------------------------------------------
# Pre-defined commonly used flows
# ---------------------------------------------------------------------------
sno-ai-setup: step0-render-vars step1.1-sno-manifests step2-rhacm-ztp-setup step3-rhacm-deploy

sno-ibi-setup: step0-render-vars step1.1-sno-manifests step2-rhacm-ztp-setup step3-rhacm-deploy \
	step5-ibi-prepare-snos step6-ibi-replace-disks

ibu-seed-image: step4-ibu-prepare-seed-cluster step5-ibi-prepare-snos

# ---------------------------------------------------------------------------
help:
	@printf '%s\n' \
		'Render vars first, then run the corresponding playbook target.' \
		'Example: make render-all && make rhacm-deploy' \
		'Existing vars must be nonempty YAML mappings. Rendering replaces them only on success.' \
		''
	@printf '%s\n' 'Steps (left) and their playbook aliases (right):'
	@printf '  %-32s%s\n' \
		'step0-render-vars'                'render-all' \
		'step1.1-sno-manifests'            'sno-manifests' \
		'step1.2-telco-core-manifests'     'telco-core-manifests' \
		'step2-rhacm-ztp-setup'            'rhacm-ztp-setup' \
		'step3-rhacm-deploy'               'rhacm-deploy' \
		'step4-ibu-prepare-seed-cluster'   'ibu-prepare-seed-cluster' \
		'step5-ibi-prepare-snos'           'ibi-prepare-snos' \
		'step6-ibi-replace-disks'          'ibi-replace-disks'
	@printf '\n%s\n' 'Individual render targets:'
	@printf '  %-32s%s\n' \
		'render-all'        'ansible/vars/all.yml from $(YQ_FILE) key all' \
		'render-telco-core' 'ansible/vars/telco-core.yml from $(YQ_FILE) key telco-core (legacy)'
	@printf '\n%s\n' 'Flows (run their steps in order; safe under make -j):'
	@printf '  %-32s%s\n' \
		'sno-ai-setup'   'step0 -> 1.1 -> 2 -> 3' \
		'sno-ibi-setup'  'sno-ai-setup -> 5 -> 6' \
		'ibu-seed-image' 'step4 -> 5'
	@printf '\n%s\n' 'Common overrides:'
	@printf '  %-32s%s\n' \
		'INV_FILE=<path>'        'ACM inventory (required when $(_INV_DIR) holds several .local files)' \
		'YQ_BIN=<path>'          'yq binary (default: $(YQ_BIN))' \
		'YQ_DIR=<dir>'           'directory holding all.yq (default: $(_YQ_DIR))' \
		'VARS_DIR=<dir>'         'ansible vars directory (default: $(_VARS_DIR))'
