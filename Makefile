VERSION_MAJOR=1
VERSION_MINOR=10
VERSION=$(VERSION_MAJOR).$(VERSION_MINOR)
FILES=mailgraph.cgi mailgraph-init README COPYING CHANGES
D=mailgraph-$(VERSION)

build:
	# D/mailgraph.pl
	mkdir $(D)
	perl embed.pl mailgraph.pl | ./isgtc_to_public >$(D)/mailgraph.pl
	perl -pi -e 's/^my \$$VERSION =.*/my \$$VERSION = "$(VERSION)";/' $(D)/mailgraph.pl
	chmod 755 $(D)/mailgraph.pl
	# mailgraph.cgi
	perl -pi -e 's/^my \$$VERSION =.*/my \$$VERSION = "$(VERSION)";/' mailgraph.cgi
	# copy the files
	gtar cf - $(FILES) | (cd mailgraph-$(VERSION) && gtar xf -)
	# tarball
	cvs tag v$(VERSION_MAJOR)_$(VERSION_MINOR)
	gtar czvf pub/mailgraph-$(VERSION).tar.gz mailgraph-$(VERSION)
	rm -rf mailgraph-$(VERSION)
	cp CHANGES pub
