// Copyright 2021 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef NET_DNS_PUBLIC_SECURE_DNS_POLICY_H_
#define NET_DNS_PUBLIC_SECURE_DNS_POLICY_H_

namespace net {

// The SecureDnsPolicy indicates whether and how a specific request or socket
// can use Secure DNS.
enum class SecureDnsPolicy {
  // Secure DNS is allowed for this request, if it is generally enabled.
  kAllow,
  // This request must not use Secure DNS, even when it is otherwise enabled.
  kDisable,
  // This request is part of the Secure DNS bootstrap process.
  kBootstrap,
};

}  // namespace net

#endif  // NET_DNS_PUBLIC_SECURE_DNS_POLICY_H_
