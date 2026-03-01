#!/bin/bash

# Copyright 2021 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail
if [[ ! -f "/sys/fs/cgroup/cgroup.controllers" ]]; then
	echo 'ERROR: this script should not be called on cgroup v1 hosts' >&2
	exit 1
fi

drain_root_cgroup() {
	local root="/sys/fs/cgroup"
	local init_scope="${root}/init.scope"
	mkdir -p "${init_scope}"
	while read -r pid; do
		if [[ -n "${pid}" && "${pid}" != "0" ]]; then
			echo "${pid}" > "${init_scope}/cgroup.procs" || true
		fi
	done < "${root}/cgroup.procs"
}

# NOTE: we can't use `test -s` because cgroup.procs is not a regular file.
if grep -qv '^0$' /sys/fs/cgroup/cgroup.procs ; then
	echo 'WARN: /sys/fs/cgroup/cgroup.procs is not empty; moving remaining processes to init.scope' >&2
	drain_root_cgroup
fi

ensure_subtree_control() {
	local group=$1
	# When cgroup.controllers is like "cpu cpuset memory io pids",
	# cgroup.subtree_control is written with "+cpu +cpuset +memory +io +pids" .
	sed -e 's/ / +/g' -e 's/^/+/' <"/sys/fs/cgroup/$group/cgroup.controllers" >"/sys/fs/cgroup/$group/cgroup.subtree_control"
}

# kubelet requires all the controllers (including hugetlb) in /sys/fs/cgroup/cgroup.controllers to be available in
# /sys/fs/cgroup/kubelet/cgroup.subtree_control.
#
# We need to update the top-level cgroup.subtree_controllers as well, because hugetlb is not present in the file by default.
ensure_subtree_control /
mkdir -p /sys/fs/cgroup/kubelet
ensure_subtree_control /kubelet
# again for kubelet.slice for systemd cgroup driver
mkdir -p /sys/fs/cgroup/kubelet.slice
ensure_subtree_control /kubelet.slice
