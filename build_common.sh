#!/bin/sh -e

# The only purpose of the above shebang is to orient shellcheck right.
# To make CI scripts maintenance simpler, copies of this file in the
# libpcap, tcpdump and tcpslice git repositories should be identical.
# Please mind that Solaris /bin/sh before 11 does not support the $()
# command substitution syntax, hence the SC2006 directives.

# A poor man's mktemp(1) for OSes that don't have one (e.g. AIX 7, Solaris 9).
mktempdir_diy() {
    while true; do
        # /bin/sh implements $RANDOM in AIX 7, but not in Solaris before 11,
        # thus use dd and od instead.
        # shellcheck disable=SC2006
        mktempdir_diy_suffix=`dd if=/dev/urandom bs=1 count=4 2>/dev/null | od -t x -A n | head -1 | tr -d '\t '`
        [ -z "$mktempdir_diy_suffix" ] && return 1
        mktempdir_diy_path="${TMPDIR:-/tmp}/${1:?}.${mktempdir_diy_suffix}"
        # "test -e" would be more appropriate, but it is not available in
        # Solaris /bin/sh before 11.
        if [ ! -d "$mktempdir_diy_path" ]; then
            mkdir "$mktempdir_diy_path"
            chmod go= "$mktempdir_diy_path"
            echo "$mktempdir_diy_path"
            break
        fi
        # Try again (AIX /dev/urandom returns zeroes quite often).
    done
}

mktempdir() {
    mktempdir_prefix=${1:-tmp}
    # shellcheck disable=SC2006
    case `uname -s` in
    Darwin|FreeBSD|NetBSD)
        # In these operating systems mktemp(1) always appends an implicit
        # ".XXXXXXXX" suffix to the requested template when creating a
        # temporary directory.
        mktemp -d -t "$mktempdir_prefix"
        ;;
    AIX)
        mktempdir_diy "$mktempdir_prefix"
        ;;
    SunOS)
        # shellcheck disable=SC2006
        case `uname -r` in
        5.10|5.11)
            mktemp -d -t "${mktempdir_prefix}.XXXXXXXX"
            ;;
        *)
            mktempdir_diy "$mktempdir_prefix"
            ;;
        esac
        ;;
    *)
        # At least Linux and OpenBSD implementations require explicit trailing
        # X'es in the template, so make it the same suffix as above.
        mktemp -d -t "${mktempdir_prefix}.XXXXXXXX"
        ;;
    esac
}

print_sysinfo() {
    uname -a
    date
}

# Try to make the current C compiler print its version information (usually
# multi-line) to stdout.
# shellcheck disable=SC2006
print_cc_version() {
    case `basename "$CC"` in
    gcc*|clang*)
        # GCC and Clang recognize --version, print to stdout and exit with 0.
        "$CC" --version
        ;;
    xl*)
        # XL C for AIX recognizes -qversion, prints to stdout and exits with 0,
        # but on an unknown command-line flag displays its man page and waits.
        "$CC" -qversion
        ;;
    sun*)
        # Sun compilers recognize -V, print to stderr and exit with an error.
        "$CC" -V 2>&1 || :
        ;;
    cc)
        case `uname -s` in
        SunOS)
            # Most likely Sun C.
            "$CC" -V 2>&1 || :
            ;;
        Darwin)
            # Most likely Clang.
            "$CC" --version
            ;;
        Linux|FreeBSD|NetBSD|OpenBSD)
            # Most likely Clang or GCC.
            "$CC" --version
            ;;
        esac
        ;;
    *)
        "$CC" --version || "$CC" -V || :
        ;;
    esac
}

# For the current C compiler try to print a short and uniform identification
# string (such as "gcc-9.3.0") that is convenient to use in a case statement.
# shellcheck disable=SC2006
cc_id() {
    cc_id_firstline=`print_cc_version | head -1`

    cc_id_guessed=`echo "$cc_id_firstline" | sed 's/^.*clang version \([0-9\.]*\).*$/clang-\1/'`
    if [ "$cc_id_firstline" != "$cc_id_guessed" ]; then
        echo "$cc_id_guessed"
        return
    fi

    cc_id_guessed=`echo "$cc_id_firstline" | sed 's/^IBM XL C.* for AIX, V\([0-9\.]*\).*$/xlc-\1/'`
    if [ "$cc_id_firstline" != "$cc_id_guessed" ]; then
        echo "$cc_id_guessed"
        return
    fi

    cc_id_guessed=`echo "$cc_id_firstline" | sed 's/^.* Sun C \([0-9\.]*\) .*$/suncc-\1/'`
    if [ "$cc_id_firstline" != "$cc_id_guessed" ]; then
        echo "$cc_id_guessed"
        return
    fi

    cc_id_guessed=`echo "$cc_id_firstline" | sed 's/^.* (.*) \([0-9\.]*\)$/gcc-\1/'`
    if [ "$cc_id_firstline" != "$cc_id_guessed" ]; then
        echo "$cc_id_guessed"
        return
    fi
}

# For the current C compiler try to print CFLAGS value that tells to treat
# warnings as errors.
# shellcheck disable=SC2006
cc_werr_cflags() {
    case `cc_id` in
    gcc-*|clang-*)
        echo '-Werror'
        ;;
    xlc-*)
        echo '-qhalt=w'
        ;;
    suncc-*)
        echo '-errwarn=%all'
        ;;
    esac
}

increment() {
    # No arithmetic expansion in Solaris /bin/sh before 11.
    echo "${1:?} + 1" | bc
}

# Display text in magenta.
echo_magenta() {
    # ANSI magenta, the imploded text, ANSI reset, newline.
    printf '\033[35;1m%s\033[0m\n' "$*"
}

# Run a command after displaying it.
run_after_echo() {
    : "${1:?}" # Require at least one argument.
    printf '$ %s\n' "$*"
    "$@"
}

print_so_deps() {
    # shellcheck disable=SC2006
    case `uname -s` in
    Darwin)
        run_after_echo otool -L "${1:?}"
        ;;
    *)
        run_after_echo ldd "${1:?}"
        ;;
    esac
}

# Beware that setting MATRIX_DEBUG for tcpdump or tcpslice will produce A LOT
# of additional output there and in any nested libpcap builds. Multiplied by
# the matrix size, the full output log size might exceed limits of some CI
# systems (as it had previously happened with Travis CI). Use with caution on
# a reduced matrix.
handle_matrix_debug() {
    [ "$MATRIX_DEBUG" != yes ] && return
    echo '$ cat Makefile [...]'
    sed '/^# DO NOT DELETE THIS LINE -- mkdep uses it.$/q' <Makefile
    run_after_echo cat config.h
    [ "$CMAKE" = yes ] || run_after_echo cat config.log
}

purge_directory() {
    # shellcheck disable=SC2006
    if [ "`uname -s`" = SunOS ] && [ "`uname -r`" = 5.11 ]; then
        # In Solaris 11 /bin/sh the pathname expansion of "*" always includes
        # "." and "..", so the straightforward rm would always fail.
        (
            cd "${1:?}"
            for pd_each in *; do
                if [ "$pd_each" != . ] && [ "$pd_each" != .. ]; then
                    rm -rf "$pd_each"
                fi
            done
        )
    else
        rm -rf "${1:?}"/*
    fi
}

# vi: set tabstop=4 softtabstop=0 expandtab shiftwidth=4 smarttab autoindent :