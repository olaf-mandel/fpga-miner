#!/bin/sh -e
#
#     Usage: $0 [ --USD|--EUR ] [ <input> [ <output> ]]
#            $0 -h|--help
#
# Reads in an Eagle BOM database in tsv format and adds prices and
# availlability columns to it. Every missing parameter is replaced by
# stdout/stdin.
#
# The recognized headers in the table are:
# Key     : Must be the header of the first column
# DigiKey : Order-Number for http://www.digikey.com/
# Avnet   : Order-Number for http://avnetexpress.avnet.com/
# All other columns will be removed from the table, capitalisation is
# important.
#
# Generates columns of this format, always following the matching Distributor:
# *_Avail : Number of on-stock items
# *_n     : Prize at the price-break for n pieces ordered
#
# The monetary unit (USD, EUR) can be selected by giving the optional --USD
# or --EUR parameter. The default value is EUR.
# 


# usage : Prints a message to stdout about this program. The message is taken
# from the first comment of the file. The $0 variable is replaced by the
# program name. If an error message was given as the first parameter, then
# prepends this to the message.
usage() {
    if [ -n "$1" ]; then
        echo "$1" >&2
    fi
    sed -n '
1n
/^$/q
s/\$0/'"${0##*/}"'/
s/^# \?//p
' "${0}" >&2
    exit 1
}


# error : Prints the usage message to stderr (including the result of the
# first parameter). Then exits with an error (exit 1).
error() {
    usage "$1" >&2
    exit 1
}


# parse_args : Parses the argument list, returning only if the arguments are
# valid and the program should do something (not --help). If help is requested,
# this is handled here. The settings by the user are stored in three global
# variables input, output and unit.
parse_args() {
    if [ $# -eq 1 ] && [ "$1" = "--help" -o "$1" = "-h" ]; then
        usage
        exit 0
    fi
    unit=EUR
    if [ $# -ge 1 ]; then
        case "$1" in
            --USD|--EUR)
                unit=${1#--}
                shift
                ;;
        esac
    fi
    if [ $# -gt 2 ]; then
        error "Too many parameters!"
    fi
    output=
    if [ $# -ge 2 -a "$2" != - ]; then
        output=$2
    fi
    input=
    if [ $# -ge 1 -a "$1" != - ]; then
        input=$1
    fi
}


# exit_trap : Clean up in case we use a temporary file and have the script
# exits.
exit_trap() {
    rm -f "${output}"
}


# fillit : Reads a table from stdin and write a modified table to stdout
# The monetary unit is given as $1.
fillit() {
    awk  -W posix -F '\t' -v unit=$1 '
# Write an error message and then exit AWK
function abort(msg) {
    print msg >"/dev/stderr";
    failed = true;
    exit 1;
}

# Simple sort: Fills the array of keys k with indices into the array a such
# that a[k[]] is sorted. Returns the number of elements.
function sort(a, k,    n, t, i, j) {
    n = 0;
    for(i in a) {
        k[n++] = i;
    }
    for(i=1; i<n; ++i)
        for(j=n-1; j>=i; j--)
            if(a[k[j-1]]>a[k[j]]) {
                t      = k[j];
                k[j]   = k[j-1];
                k[j-1] = t;
            }
    return n;
} 


# Searches the element x in the array a[j, *] and returns the key that
# corresponds to that. Returns an empty string if not found.
function aindex2(a, j, x,    k) {
    for(k in a) {
        if(k !~ "^" j SUBSEP)
            continue;
        if(a[k] == x) {
            gsub("^" j SUBSEP, "", k);
            return k;
        }
    }
    return "";
}


# Returns the value of the index k in breaks[j, k] that corresponds to
# the break0 argument. Expands the breaks and n_breaks variables if required.
function find_break(j, break0,    k) {
    k = aindex2(breaks, j, break0);
    if(k == "") {
        k = n_breaks[j]++;
        breaks[j, k] = break0;
    }
    return k;
}


# Reads in the webpage for the DigiKey ordercodes(i, j) and stores the
# results in the global variables availables[i, j], n_breaks[j], breaks[j, *]
# and prices[i, j, *].
function query_DigiKey(i, j,    url, cmd, in_price_table, this_break, \
    this_price, k) {
    if(ordercodes[i, j] == "")
        return;
    if(unit == "EUR")
        url = "http://search.digikey.de/scripts/DkSearch/dksus.dll?" \
            "Detail&site=de;lang=de&name=" ordercodes[i, j];
    else
        url = "http://search.digikey.de/scripts/DkSearch/dksus.dll?" \
            "Detail&name=" ordercodes[i, j];
    cmd = "wget --output-document=- --quiet \"" url "\"";
    in_price_table = false;
    while((cmd | getline) == 1) {
        if($0 ~ "<td [^>]*id=quantityavailable[^>]*>[^<]*<") {
            availables[i, j] = $0;
            gsub(".*<td [^>]*id=quantityavailable[^>]*>", "", \
                availables[i, j]);
            gsub("<.*", "", availables[i, j]);
            gsub("[,.]", "", availables[i, j]);
            availables[i, j] = availables[i, j] + 0;
        }
        if($0 ~ "<table [^>]*id=pricing")
            in_price_table = 1;
        if(in_price_table && ($0 ~ "<td[^>]*>[^<]*</td><td[^>]*>[^<]*" \
            "</td><td")) {
            this_break = $0;
            gsub("</td>.*", "", this_break);
            gsub(".*<td[^>]*>", "", this_break);
            this_price = $0;
            gsub(".*<td[^>]*>" this_break "</td><td[^>]*>", "", this_price);
            gsub("</td>.*", "", this_price);
            gsub("[,.]", "", this_break);
            gsub("[,.]", ".", this_price);
            k = find_break(j, this_break + 0);
            prices[i, j, k] = this_price;
        }
        if($0 ~ "</table>")
            in_price_table = false;
    }
    close(cmd);
}


# Reads in the webpage for the Avnet ordercodes(i, j) and stores the
# results in the global variables availables[i, j], n_breaks[j], breaks[j, *]
# and prices[i, j, *].
function query_Avnet(i, j,    url, cookies, cmd, n_subcats, subcats, subcat, s,
    found_it, in_row, expect_pn, in_price, expect_avail, pn, price, \
    this_break, this_price, k, avail) {
    if(ordercodes[i, j] == "")
        return;
    url = "http://avnetexpress.avnet.com/store/em/EMController?N=0&" \
        "action=products&term=" ordercodes[i, j];
    cmd = "mktemp";
    cmd | getline cookies;
    close(cmd);
    cmd = "wget --output-document=- --keep-session-cookies --save-cookies " \
        cookies " --quiet \"" url "\"";
    n_subcats  = 0;
    no_subcats = false;
    while((cmd | getline) == 1) {
        if($0 ~ "<a class=\"medium\"[^>]*href=\"[^\"]*\"") {
            subcat = $0;
            gsub(".*<a class=\"medium\"[^>]*href=\"", "", subcat);
            gsub("\".*", "", subcat);
            gsub("&amp;", "\\&", subcat);
            if(subcat !~ "^[a-zA-Z]*://")
                if(subcat ~ "^/")
                    subcat = "http://avnetexpress.avnet.com" subcat;
                else
                    subcat = "http://avnetexpress.avnet.com/store/em/" subcat;
            subcats[n_subcats++] = subcat;
        }
        if($0 ~ "id=\"resultsTbl1\"") {
            subcats[0] = url;
            n_subcats  = 1;
            break;
        }
    }
    close(cmd);
    found_it = false;
    for(s in subcats) {
        subcat = subcats[s];
        gsub("&", "%26", subcat);
        gsub("/", "%2F", subcat);
        gsub(":", "%3A", subcat);
        gsub("=", "%3D", subcat);
        gsub("\\?", "%3F", subcat);
        url = "http://avnetexpress.avnet.com/store/em/SetCurrencyPreference?" \
            "displayCurrency=" unit "&URL=" subcat;
        cmd = "wget --output-document=- --load-cookies " cookies \
            " --quiet \"" url "\"";
        in_row       = false;
        expect_pn    = false;
        in_price     = false;
        expect_avail = false;
        while((cmd | getline) == 1) {
            if($0 ~ "<tr[^>]*id=\"row_[0-9]*\"")
                in_row = true;
            if(expect_pn) {
                pn = $0;
                gsub("^[ 	]*", "", pn);
                gsub("<br/>.*", "", pn);
                gsub("\r$", "", pn);
                if(pn != ordercodes[i, j])
                    in_row = false;
                expect_pn = false;
            }
            if(in_row && $0 ~ "id=\"row_[0-9]*_partNumber\"")
                expect_pn = true;
            if(in_row && $0 ~ "class=\"small partNotAvailableInRegion\"") {
                in_row = false;
            }
            if(in_row && $0 ~ "style=\"white-space:nowrap;vertical-align:" \
                "top;text-align:right;padding-right:3px; \"")
                in_price = true;
            if(in_price && $0 ~ "<div.*<br></div>") {
                price = $0;
                gsub(".*<div[^>]*>", "", price);
                gsub("<br></div>.*", "", price);
                if(price ~ "<br>")
                    while(price != "") {
                        this_break = price;
                        gsub("-.*", "", this_break);
                        gsub("\\+$", "", this_break);
                        this_price = price;
                        gsub("<br>.*", "", this_price);
                        gsub(".*-", "", this_price);
                        gsub("[$€]", "", this_price);
                        k = find_break(j, this_break + 0);
                        prices[i, j, k] = this_price;
                        if(price ~ "<br>")
                            gsub("^[^<]*<br>", "", price);
                        else
                            price = "";
                    }
                else {
                    this_break = 1;
                    this_price = price;
                    gsub("[$€]", "", this_price);
                    k = find_break(j, this_break);
                    prices[i, j, k] = this_price;
                }
                in_price = false;
            }
            if(expect_avail && $0 ~ "<br/>") {
                avail = $0;
                gsub("^[ 	]*", "", avail);
                gsub("<br/>.*", "", avail);
                gsub("&nbsp;", " ", avail);
                gsub("Stock", "", avail);
                gsub("No *", "0", avail);
                availables[i, j] = avail + 0;
                found_it = true;
                break;
            }
            if(in_row && $0 ~ "style=\"white-space:nowrap;vertical-align:" \
                "top;text-align:center; \"")
                expect_avail = true;
            if($0 ~ "</tr>")
                in_row = false;
        }
        close(cmd);
        if(found_it)
            break;
    }
    system("rm " cookies);
}


# Initialise several global variables
BEGIN {
    # Define suppliers
    suppl[0] = "DigiKey";
    suppl[1] = "Avnet";
    n_suppl  = 2;
    # Initialise other variables
    true     = 1;
    false    = 0;
    n_cols   = 0;
    OFS      = FS;
    failed   = false;
}

# Read header line
NR == 1 {
    if($1 != "Key")
        abort("First columns header must be \"Key\"");
    for(i=2; i<=NF; ++i)
        for(j in suppl)
            if($i == suppl[j])
                if(j in cols)
                    abort("Found multiple \"" suppl[j] "\" columns");
                else {
                    cols[j]     = i;
                    n_breaks[j] = 0;
                    n_cols++;
                }
}

# Read all other lines
NR > 1 {
    keys[NR-2] = $1;
    for(i in cols)
        ordercodes[NR-2, i] = $cols[i];
}

# Unless abort() was called before, query suppliers and output results
END {
    if(failed)
        exit 1;
    # Query supplier webpages
    for(i=0; i<NR-1; ++i)
        for(j in cols)
            if(suppl[j] == "DigiKey")
                query_DigiKey(i, j);
            else if(suppl[j] == "Avnet")
                query_Avnet(i, j);
    # Output results
    n = sort(breaks, s);

    printf "Keys";
    for(j in cols) {
        printf "%s%s%s%s", OFS, suppl[j], OFS, suppl[j] "_Avail";
        for(k=0; k<n; ++k) {
            if(s[k] !~ "^" j SUBSEP)
                continue;
            printf "%s%s", OFS, suppl[j] "_" breaks[s[k]];
        }
    }
    printf ORS;
    for(i=0; i<NR-1; ++i) {
        printf "%s", keys[i];
        for(j in cols) {
            printf "%s%s%s%s", OFS, ordercodes[i, j], OFS, availables[i, j];
            for(k=0; k<n; ++k) {
                if(s[k] !~ "^" j SUBSEP)
                    continue;
                printf "%s%s", OFS, prices[i, s[k]];
            }
        }
        printf ORS;
    }
}'
}


### Main function
# Parse arguments and handle the special case input = output
parse_args "$@"
origout=
if [ -n "${output}" -a "${input}" = "${output}" ]; then
    origout=${output}
    output=$(mktemp "${output}.XXXXXXXX")
    trap exit_trap EXIT SIGHUP SIGINT SIGQUIT SIGTERM
fi

# Actually do the job
(
    if [ -n "${input}" ]; then
        cat "${input}"
    else
        cat
    fi
) | \
fillit "${unit}" \
 | (
    if [ -n "${output}" ]; then
        cat >"${output}"
    else
        cat
    fi
)

# Handle the special case input = output
if [ -n "${origout}" ]; then
    cat "${output}" >"${origout}"
fi

exit 0

