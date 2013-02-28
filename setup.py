from setuptools import setup, find_packages
from setuptools.extension import Extension

try:
    from Cython.Distutils import build_ext
    cmdclass = {'build_ext': build_ext}
    wsgi = Extension('swiftcellerate.wsgi', ['swiftcellerate/wsgi.pyx'], libraries=[])
    libeventhub = Extension('swiftcellerate.libeventhub', ['swiftcellerate/libeventhub.pyx'], libraries=['event'])
    tpool = Extension('swiftcellerate.tpool', ['swiftcellerate/tpool.pyx'], libraries=[])
    bufferedio = Extension('swiftcellerate.bufferedio', ['swiftcellerate/bufferedio.pyx'], libraries=[])
    fileio = Extension('swiftcellerate.fileio', ['swiftcellerate/fileio.pyx'], libraries=['aio'])
except ImportError:
    cmdclass = {}
    wsgi = Extension('swiftcellerate.wsgi', ['swiftcellerate/wsgi.c'], libraries=[])
    libeventhub = Extension('swiftcellerate.libeventhub', ['swiftcellerate/libeventhub.c'], libraries=['event'])
    tpool = Extension('swiftcellerate.tpool', ['swiftcellerate/tpool.c'], libraries=[])
    bufferedio = Extension('swiftcellerate.bufferedio', ['swiftcellerate/bufferedio.c'], libraries=[])
    fileio = Extension('swiftcellerate.fileio', ['swiftcellerate/fileio.c'], libraries=['aio'])

setup(
    name='swiftcellerate',
    description='Swiftcellerate',
    packages=find_packages(exclude=[]),
    install_requires=['eventlet'],
    cmdclass=cmdclass,
    ext_modules=[wsgi, libeventhub, tpool, bufferedio, fileio],
    entry_points={
        'console_scripts': [
        ],
        'paste.filter_factory': [
            'swiftcellerate=swiftcellerate.middleware:filter_factory',
        ],
    },
)

