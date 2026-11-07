// Copyright (c) 2026, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

const target = new URL('./', window.location.href);
target.pathname = target.pathname.replace(/\/embed-flutter(?:\.html)?\/?$/, '/');
target.search = window.location.search;
target.searchParams.set('embed', 'true');
target.hash = window.location.hash;
window.location.replace(target.toString());
