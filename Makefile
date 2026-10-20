PYTHON ?= python3

.PHONY: fixtures test demo schemas app

fixtures:
	$(PYTHON) fixtures/generate.py

test:
	PYTHONPATH=src $(PYTHON) -m unittest discover -s tests -v

demo: fixtures
	$(PYTHON) -I airs_cli.py audit -- fixtures/generated/mixed-regular.macho

schemas:
	$(PYTHON) scripts/generate-schemas.py

app:
	bash scripts/package-app.sh
