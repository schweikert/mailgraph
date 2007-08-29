VERSION_MAJOR=1
VERSION_MINOR=13
VERSION=$(VERSION_MAJOR).$(VERSION_MINOR)
FILES=mailgraph.cgi mailgraph-init README COPYING CHANGES
SVNREPO=svn://svn.schweikert.ch/mailgraph
D=mailgraph-$(VERSION)

all: tag-build

tag-build: tag build

tag:
	@svn st | grep 'M' >/dev/null; \
		if [ $$? -eq 0 ]; then \
			echo "Commit your changes!"; \
			exit 1; \
		fi
	@if svn ls $(SVNREPO)/tags/version-$(VERSION_MAJOR).$(VERSION_MINOR) >/dev/null; then \
		echo "Tag version-$(VERSION_MAJOR).$(VERSION_MINOR) already exists!"; \
		exit 1; \
	fi
	svn cp -m 'Tag version $(VERSION_MAJOR).$(VERSION_MINOR)' $(SVNREPO)/trunk $(SVNREPO)/tags/version-$(VERSION_MAJOR).$(VERSION_MINOR)

build:
	# D/mailgraph.pl
	mkdir $(D)
	perl embed.pl mailgraph.pl >$(D)/mailgraph.pl
	perl -pi -e 's/^my \$$VERSION =.*/my \$$VERSION = "$(VERSION)";/' $(D)/mailgraph.pl
	chmod 755 $(D)/mailgraph.pl
	# mailgraph.cgi
	perl -pi -e 's/^my \$$VERSION =.*/my \$$VERSION = "$(VERSION)";/' mailgraph.cgi
	# copy the files
	tar cf - $(FILES) | (cd mailgraph-$(VERSION) && tar xf -)
	# tarball
	tar czvf pub/mailgraph-$(VERSION).tar.gz mailgraph-$(VERSION)
	rm -rf mailgraph-$(VERSION)
	cp CHANGES pub

.PHONY: all tag-build merge build
