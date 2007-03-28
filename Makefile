VERSION_MAJOR=1
VERSION_MINOR=14
VERSION=$(VERSION_MAJOR).$(VERSION_MINOR)
FILES=mailgraph.cgi mailgraph-init README COPYING CHANGES
D=mailgraph-$(VERSION)

tag:
	@svk st | grep 'M' >/dev/null; \
		if [ $$? -eq 0 ]; then \
			echo "Commit your changes!"; \
			exit 1; \
		fi
	svk cp -m 'Tag version $(VERSION_MAJOR).$(VERSION_MINOR)' //mailgraph/trunk //mailgraph/tags/version-$(VERSION_MAJOR).$(VERSION_MINOR)

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
	cvs tag v$(VERSION_MAJOR)_$(VERSION_MINOR)
	tar czvf pub/mailgraph-$(VERSION).tar.gz mailgraph-$(VERSION)
	rm -rf mailgraph-$(VERSION)
	cp CHANGES pub
