#!/bin/bash
app_name=app

build_flags='-error-pos-style:unix -warnings-as-errors -vet-cast -strict-style -use-single-module'
build_flags="$build_flags -debug"

odin build . -out:./$app_name $build_flags
