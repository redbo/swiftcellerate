Experimental acceleration for Swift.  This just replaces some Swift
dependencies and internals that are known to be slow with compiled/optimized
versions.

Currently includes:
* tpool
* libevent-based eventlet hub
* wsgi server

It includes some middleware that will monkey patch all of the optimizations
into place.  Just add this to a .conf file:

[filter:swiftcellerate]
use = egg:swiftcellerate#swiftcellerate

Then add "swiftcellerate" to the pipeline.
