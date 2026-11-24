# Else exist specifically for clang
ifeq ($(CXX),g++)
    EXTRA_FLAGS = --no-gnu-unique
else
    EXTRA_FLAGS =
endif

CXXFLAGS ?= -O2
CXXFLAGS += -shared -fPIC -std=c++2b -Wno-c++11-narrowing
INCLUDES = `pkg-config --cflags pixman-1 libdrm hyprland libinput libudev wayland-server xkbcommon`
LIBS =

SRC = main.cpp tabDeco.cpp
TARGET = hypr-group-tabs.so

# The plugin compiles in the commit hash of the Hyprland headers it is built against (src/version.h, GIT_COMMIT_HASH), and at
# load it refuses a running Hyprland with another hash ("Version mismatch"). A Hyprland update changes that hash and nothing
# the plugin's own files show, so the build follows it: HASH_STAMP holds the hash of the last build and is rewritten (the .so
# rebuilt) only when the headers' hash differs. The headers are wherever pkg-config's hyprland.pc says (here hyprpm's root).
HYPR_SRC_DIR  := $(patsubst -I%,%,$(filter %/hyprland/src,$(shell pkg-config --cflags-only-I hyprland)))
HYPR_VERSION_H = $(HYPR_SRC_DIR)/version.h
HASH_STAMP     = .hyprland-hash
hash_of        = sed -n 's/^\#define GIT_COMMIT_HASH *"\(.*\)"/\1/p'

all: $(TARGET)

$(TARGET): $(SRC) $(wildcard *.hpp) $(HASH_STAMP)
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(EXTRA_FLAGS) $(INCLUDES) $(SRC) -o $@ $(LIBS)

$(HASH_STAMP): FORCE
	@h=$$($(hash_of) "$(HYPR_VERSION_H)"); \
	 [ -n "$$h" ] || { echo "no GIT_COMMIT_HASH in $(HYPR_VERSION_H): are the hyprland headers installed?" >&2; exit 1; }; \
	 [ "$$h" = "$$(cat $@ 2>/dev/null)" ] || { echo "$$h" > $@; echo "Hyprland headers are $$h: building for them"; }

# The four hashes that must agree, read only: the headers, the running Hyprland, this build, the installed copy.
status:
	@echo "headers   $$($(hash_of) "$(HYPR_VERSION_H)")  ($(HYPR_VERSION_H))"
	@echo "running   $$(hyprctl -j version 2> /dev/null | sed -n 's/.*"commit": *"\([0-9a-f]*\)".*/\1/p')  (hyprctl version)"
	@echo "built     $$(strings $(TARGET) 2> /dev/null | grep -m1 -E '^[0-9a-f]{40}$$')  ($(TARGET))"
	@echo "installed $$(strings $(DEST)/$(TARGET) 2> /dev/null | grep -m1 -E '^[0-9a-f]{40}$$')  ($(DEST)/$(TARGET))"

# The user's own layout for hand-built plugins (glasscope lives beside it).
# Not run by anyone but the user.
DEST = $(HOME)/.local/lib/hyprland-plugins/hypr-group-tabs

install: $(TARGET)
	install -Dm755 $(TARGET) $(DEST)/$(TARGET)

clean:
	rm -f ./$(TARGET) ./$(HASH_STAMP)

FORCE:

.PHONY: all clean install status FORCE
