VERSION=0.6.1p3
COMPONENT=chunter
SUFFIX:=$(shell echo $(SUFFIX))
BASENAME:=$(COMPONENT)-$(VERSION)$(SUFFIX)
.PHONY: package clean

clean:
	rm *.gz

package:
	cp install.sh $(BASENAME)
	cd .. && tar -cf pkg/$(BASENAME).tar $(COMPONENT)
	uuencode $(BASENAME).tar $(BASENAME).tar >> $(BASENAME)
	-rm $(BASENAME).gz $(BASENAME).tar
	gzip -9 $(BASENAME)
