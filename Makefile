APP_NAME=chunter
APP_DIR=$(shell if [ -d apps/$(APP_NAME) ]; then echo "apps/$(APP_NAME)"; else echo; fi)
OBJ=$(shell ls $(APP_DIR)/src/*.erl | sed -e 's/\.erl$$/.beam/' | sed -e 's;^$(APP_DIR)/src;$(APP_DIR)/ebin;g') $(shell ls $(APP_DIR)/src/*.app.src | sed -e 's/\.src$$//g' | sed -e 's;^$(APP_DIR)/src;$(APP_DIR)/ebin;g')
DEPS=$(shell cat rebar.config  |sed -e 's/%.*//'| sed -e '/{\(\w\+\), [^,]\+, {\w\+, [^,]\+, {[^,]\+, [^}]\+}}},\?/!d' | sed -e 's;{\(\w\+\), [^,]\+, {\w\+, [^,]\+, {[^,]\+, [^}]\+}}},\?;deps/\1/rebar.config;')
ERL=erl
PA=$(shell pwd)/$(APP_DIR)/ebin
ERL_LIBS=$(shell pwd)/deps/
REBAR=$(shell pwd)/rebar

all: $(DEPS) $(OBJ)

rel: all remove_trash FORCE
	-rm -r rel/$(APP_NAME)
	cd rel; ../rebar generate

package:
	make -C rel/pkg package
echo:
	echo $(DEPS)

deps:
	$(REBAR) get-deps

tar: rel
	cd rel; tar jcvf $(APP_NAME).tar.bz2 $(APP_NAME)

clean: FORCE
	$(REBAR) clean
	-rm *.beam erl_crash.dump
	-rm -r rel/$(APP_NAME)
	-rm rel/$(APP_NAME).tar.bz2

$(DEPS):
	$(REBAR) get-deps
	$(REBAR) compile

$(APP_DIR)/ebin/%.app: $(APP_DIR)/src/%.app.src
	$(REBAR) compile

$(APP_DIR)/ebin/%.beam: $(APP_DIR)/src/%.erl
	$(REBAR) compile

shell: all
	ERL_LIBS="$(ERL_LIBS)" $(ERL) -pa $(PA) -config standalone -sname $(APP_NAME) -s $(APP_NAME)
	rm *.beam || true
	[ -f erl_crash.dump ] && rm erl_crash.dump || true

test: all xref
	$(REBAR) skip_deps=true eunit

xref: all
	$(REBAR) xref skip_deps=true

FORCE:

manifest: rel
	./tools/mkmanifest > manifest

remove_trash:
	-find . -name "*~" -exec rm {} \;.
	-rm *.beam erl_crash.dump || true
