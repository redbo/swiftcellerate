Experimental acceleration for Swift.  This just replaces some Swift
dependencies and internals that are known to be slow with compiled/optimized
versions.

Currently includes:
* libevent-based eventlet hub
* faster wsgi server with sendfile() support
* faster tpool
* basic object server asynchronous file i/o

It includes some middleware that will monkey patch all of the optimizations
into place.  Just add this to a .conf file:

    [filter:swiftcellerate]
    use = egg:swiftcellerate#swiftcellerate

Then add "swiftcellerate" to the pipeline.  The items to patch will be
configurable later.
