Containerization
====

Root is not required to build or run the image.


Images can be built like this,

```
$ buildah unshare ./images/base.sh
```

Containers can be run like this,

```
$ podman run -p 0.0.0.0:5000:5000 localhost/tcms
```
