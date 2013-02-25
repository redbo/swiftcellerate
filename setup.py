from setuptools import setup, find_packages
from setuptools.extension import Extension

try:
    from Cython.Distutils import build_ext
    cmdclass = {'build_ext': build_ext}
    wsgi = Extension('swiftcellerate.wsgi', ['swiftcellerate/wsgi.pyx'], libraries=[])
    libeventhub = Extension('swiftcellerate.libeventhub', ['swiftcellerate/libeventhub.pyx'], libraries=['event'])
except ImportError:
    cmdclass = {}
    wsgi = Extension('swiftcellerate.wsgi', ['swiftcellerate/wsgi'], libraries=[])
    libeventhub = Extension('swiftcellerate.libeventhub', ['swiftcellerate/libeventhub.c'], libraries=['event'])

setup(
    name='swiftcellerate',
    description='Swiftcellerate',
    packages=find_packages(exclude=[]),
    install_requires=['eventlet'],
    cmdclass=cmdclass,
    ext_modules=[wsgi, libeventhub],
    entry_points={
        'console_scripts': [
        ],
        'paste.filter_factory': [
        ],
    },
)

