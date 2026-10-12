# Host build of the OpenVR shim and its tests (Linux or macOS).
# On Vision Pro the same sources are compiled into Klepton's runtime with
# platform/klvr_platform_klepton.c instead of the null platform; see README.md.
#
#   make test        build and run the tests
#   make regen       regenerate src/generated/ (needs OPENVR_REPO and STEAMVR_UNITY_REPO)
#
# VULKAN_INCLUDE must point at Khronos Vulkan-Headers/include.

CXX      ?= c++
CC       ?= cc
VULKAN_INCLUDE ?= /usr/include
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++17 -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -Werror=missing-declarations \
            -DVR_API_EXPORT -Isrc -iquote third_party/openvr -I$(VULKAN_INCLUDE)
CFLAGS   ?= -O2 -g
CFLAGS   += -std=gnu11 -fPIC -Wall -Wextra

SRC  = src/klvr_core.cpp src/klvr_private.cpp src/klvr_overlay.cpp src/klvr_registry.cpp src/klvr_system.cpp src/klvr_compositor.cpp \
       src/klvr_vk_submit.cpp src/klvr_input.cpp src/klvr_skeleton.cpp src/klvr_json.cpp src/klvr_misc.cpp src/klvr_trace.cpp
OBJ  = $(SRC:src/%.cpp=build/%.o)

ifeq ($(shell uname -s),Darwin)
# The optional Klepton stack dumper is absent in the null platform. Darwin
# needs its unresolved weak import explicitly allowed, and uses @loader_path.
HOST_LINK_FLAGS = -Wl,-U,_kl_fault_print_frames -Wl,-install_name,@rpath/libklvr_openvr_null.so
HOST_RPATH = @loader_path
else
HOST_RPATH = $$ORIGIN
endif

all: build/libklvr_openvr_null.so build/test_shim

build/%.o: src/%.cpp src/*.h src/generated/*
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/klvr_platform_null.o: platform/klvr_platform_null.c platform/klvr_platform_null.h src/klvr_platform.h
	@mkdir -p build
	$(CC) $(CFLAGS) -c $< -o $@

build/libklvr_openvr_null.so: $(OBJ) build/klvr_platform_null.o
	$(CXX) -shared $(HOST_LINK_FLAGS) -o $@ $^ -lpthread

build/test_shim: tests/test_shim.cpp build/libklvr_openvr_null.so
	$(CXX) $(CXXFLAGS) -Iplatform -o $@ tests/test_shim.cpp -Lbuild -lklvr_openvr_null -Wl,-rpath,'$(HOST_RPATH)' -lpthread

build/test_hand_tracking: tests/test_hand_tracking.c ../xr/kl_hand_tracking.c ../xr/kl_hand_tracking.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ tests/test_hand_tracking.c ../xr/kl_hand_tracking.c -lpthread -lm

test: build/test_shim build/test_hand_tracking
	cd tests && ../build/test_shim
	./build/test_hand_tracking

regen:
	python3 tools/gen_vtables.py $(OPENVR_REPO)
	python3 tools/gen_hand_poses.py $(STEAMVR_UNITY_REPO)

clean:
	rm -rf build

.PHONY: all test regen clean
