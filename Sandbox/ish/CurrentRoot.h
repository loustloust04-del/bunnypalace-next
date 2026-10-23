//
//  CurrentRoot.h
//  MemoryPalace — 搬自 OpenMinis src/ios/iSH，上游 iSH app/CurrentRoot.h
//  SPDX-License-Identifier: GPL-3.0-only
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis), src/ios/iSH/CurrentRoot.h,
//  licensed under the GNU General Public License v3.0.
//  Originally from iSH (https://github.com/ish-app/ish), app/CurrentRoot.h, GPL-3.0 with the additional terms in iSH's LICENSE.IOS.
//  Modifications Copyright (C) 2026 Mneme Atrium contributors, also under GPL-3.0.
//  This file is GPL-3.0; it is combined with the AGPL-3.0 app under GPL-3.0 §13.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Apply rootfs patches from RootfsPatch.bundle on boot.
/// The bundle contains a manifest.plist with a version number and file list.
/// Files are written to guest fs when the bundle version exceeds /ish/overlay-version.
void FsApplyOverlay(void);

NS_ASSUME_NONNULL_END
