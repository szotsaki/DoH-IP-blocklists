#!/bin/sh
# doh-lookup - retrieve IPv4/IPv6 addresses via dig from a given domain list
# and write the adjusted output to separate lists (IPv4/IPv6 addresses plus domains)
# Copyright (c) 2019-2022 Dirk Brenken (dev@brenken.org)
#
# This is free software, licensed under the GNU General Public License v3.

# disable (s)hellcheck in release
# shellcheck disable=all

# prepare environment
#
export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
input="./doh-domains_overall.txt"
upstream="1.1.1.1 8.8.8.8 77.88.8.88 223.5.5.5"
check_domains="google.com heise.de openwrt.org"
wc_tool="$(command -v wc)"
dig_tool="$(command -v dig)"
awk_tool="$(command -v awk)"
: >"./ipv4.tmp"
: >"./ipv6.tmp"
: >"./domains.tmp"
: >"./domains_abandoned.tmp"

# sanity pre-checks
#
if [ ! -x "${wc_tool}" ] || [ ! -x "${dig_tool}" ] || [ ! -x "${awk_tool}" ] || [ ! -s "${input}" ] || [ -z "${upstream}" ]; then
	printf "%s\n" "ERR: general pre-check failed"
	exit 1
fi

for domain in ${check_domains}; do
	for resolver in ${upstream}; do
		out="$("${dig_tool}" "@${resolver}" "${domain}" A "${domain}" AAAA +noall +answer +time=5 +tries=1 2>/dev/null)"
		if [ -z "${out}" ]; then
			printf "%s\n" "ERR: domain pre-check failed"
			exit 1
		else
			ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{printf "%s ",$NF}')"
			if [ -z "${ips}" ]; then
				printf "%s\n" "ERR: ip pre-check failed"
				exit 1
			fi
		fi
	done
done

# domain per resolver processing
#
cnt="1"
domain_cnt="0"
ip_cnt="0"
while IFS= read -r domain; do
	(
		printf "%s\n" "$(date +%D-%T) ::: Start processing '${domain}' ..."
		domain_ok="false"
		for resolver in ${upstream}; do
			out="$("${dig_tool}" "@${resolver}" "${domain}" A "${domain}" AAAA +noall +answer +time=5 +tries=1 2>/dev/null)"
			if [ -n "${out}" ]; then
				ips="$(printf "%s" "${out}" | "${awk_tool}" '/^.*[[:space:]]+IN[[:space:]]+A{1,4}[[:space:]]+/{printf "%s ",$NF}')"
				if [ -n "${ips}" ]; then
					for ip in ${ips}; do
						if [ "${ip%%.*}" = "0" ] || [ -z "${ip%%::*}" ]; then
							continue
						else
							if ipcalc-ng -cs "${ip}"; then
								domain_ok="true"
								ip_cnt="$((ip_cnt + 1))"
								if [ "${ip##*:}" = "${ip}" ]; then
									printf "%-20s%s\n" "${ip}" "# ${domain}" >>./ipv4.tmp
								else
									printf "%-40s%s\n" "${ip}" "# ${domain}" >>./ipv6.tmp
								fi
							fi
						fi
					done
				fi
			fi
		done
		if [ "${domain_ok}" = "false" ]; then
			printf "%s\n" "${domain}" >>./domains_abandoned.tmp
		else
			printf "%s\n" "${domain}" >>./domains.tmp
		fi
	) &
	domain_cnt="$((domain_cnt + 1))"
	hold="$((cnt % 2048))"
	if [ "${hold}" = "0" ]; then
		wait
		cnt="1"
	else
		cnt="$((cnt + 1))"
	fi
done <"${input}"
wait

# sanity re-checks
#
if [ ! -s "./ipv4.tmp" ] || [ ! -s "./ipv6.tmp" ] || [ ! -s "./domains.tmp" ] || [ ! -f "./domains_abandoned.tmp" ]; then
	printf "%s\n" "ERR: general re-check failed"
	exit 1
fi

cnt_bad="$("${wc_tool}" -l "./domains_abandoned.tmp" 2>/dev/null | "${awk_tool}" '{print $1}')"
max_bad="$(($("${wc_tool}" -l "${input}" 2>/dev/null | awk '{print $1}') * 20 / 100))"
if [ "${cnt_bad:-"0"}" -ge "${max_bad:-"0"}" ]; then
	printf "%s\n" "ERR: count re-check failed"
	exit 1
fi

# final sort/merge step
#
sort -b -u -n -t. -k1,1 -k2,2 -k3,3 -k4,4 "./ipv4.tmp" >"./doh-ipv4.txt"
sort -b -u -k1,1 "./ipv6.tmp" >"./doh-ipv6.txt"
sort -b -u "./domains.tmp" >"./doh-domains.txt"
sort -b -u "./domains_abandoned.tmp" >"./doh-domains_abandoned.txt"
cnt_ipv4="$("${awk_tool}" 'END{printf "%d",NR}' "./${feed_name}-ipv4.txt" 2>/dev/null)"
cnt_ipv6="$("${awk_tool}" 'END{printf "%d",NR}' "./${feed_name}-ipv6.txt" 2>/dev/null)"
rm "./ipv4.tmp" "./ipv6.tmp" "./domains.tmp" "./domains_abandoned.tmp"
printf "%s\n" "$(date +%D-%T) ::: Finished processing, domains: ${domain_cnt}, IPs: ${ip_cnt}, unique IPv4: ${cnt_ipv4}, unique IPv6: ${cnt_ipv6}"
