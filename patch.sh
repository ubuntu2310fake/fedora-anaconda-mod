#!/bin/bash
# ==============================================================================
# SCRIPT VÁ LỖI CÀI ĐẶT ANACONDA & COCKPIT WEB UI (FEDORA MOD)
# ==============================================================================
# Hỗ trợ:
#   1. Bypass Format ổ cứng NVMe (nvme0n1).
#   2. Hiển thị bảng cấu hình Sao chép dữ liệu (Post-install Custom Data Copy).
#   3. Cho phép tắt/bật nút Reformat (Định dạng lại) trên giao diện Web UI.
#   4. Tự động sao chép thư mục từ phân vùng Đích sau khi cài đặt hoàn tất.
# ==============================================================================

# Yêu cầu quyền Root để chạy script này
if [ "$EUID" -ne 0 ]; then
  echo "Vui lòng chạy script bằng quyền root: sudo $0"
  exit 1
fi

echo "=================================================="
echo "1. Đang cài đặt Bản vá Backend Python (pyanaconda)..."
echo "=================================================="

PYANACONDA_DIR=$(python3 -c "import pyanaconda; import os; print(os.path.dirname(pyanaconda.__file__))" 2>/dev/null | tail -n 1)
if [ -z "$PYANACONDA_DIR" ]; then
    echo "LỖI: Không tìm thấy thư mục cài đặt pyanaconda trong hệ thống!"
    exit 1
fi
echo "Thư mục pyanaconda được phát hiện tại: $PYANACONDA_DIR"

cat << 'PY_EOF' > "$PYANACONDA_DIR/__init__.py"
import sys
import logging

# Cấu hình log của bản vá để xuất ra stdout/anaconda log
log = logging.getLogger("anaconda.patch")
log.setLevel(logging.DEBUG)

if not log.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(logging.DEBUG)
    formatter = logging.Formatter('[PATCH] %(asctime)s - %(levelname)s - %(message)s')
    handler.setFormatter(formatter)
    log.addHandler(handler)

log.info("Installing Anaconda/Blivet NVMe bypass and Custom Post-Install Copy monkey patch...")

# Helper functions to safely mark and check patched status of properties/functions
def mark_patched(obj):
    if isinstance(obj, property):
        if obj.fget:
            obj.fget.__patched__ = True
    else:
        obj.__patched__ = True

def is_patched(obj):
    if isinstance(obj, property):
        return obj.fget and getattr(obj.fget, '__patched__', False)
    return getattr(obj, '__patched__', False)

# ----------------- Các hàm vá lỗi (Patching Functions) -----------------

def patch_device_format(module):
    cls = getattr(module, 'DeviceFormat', None)
    if cls and hasattr(cls, 'create'):
        orig_create = cls.create
        if not getattr(orig_create, '__patched__', False):
            log.info("Patching blivet.formats.DeviceFormat.create to prevent nvme0n1 format")
            def patched_create(self, **kwargs):
                device_path = kwargs.get('device') or getattr(self, 'device', None)
                if device_path and 'nvme0n1' in str(device_path):
                    log.info("[PATCH] Bypassing format creation to keep old filesystem/data on %s", device_path)
                    self.exists = True
                    return
                return orig_create(self, **kwargs)
            patched_create.__patched__ = True
            cls.create = patched_create

def patch_blivet_class(module):
    cls = getattr(module, 'Blivet', None)
    if cls:
        if hasattr(cls, 'ignored_disks'):
            orig_prop = getattr(cls, 'ignored_disks')
            if is_patched(orig_prop):
                return
        
        log.info("Patching blivet.blivet.Blivet class")
        @property
        def ignored_disks(self):
            val = getattr(self, '_ignored_disks_internal', [])
            return [d for d in val if 'nvme0n1' not in d]

        @ignored_disks.setter
        def ignored_disks(self, value):
            self._ignored_disks_internal = [d for d in value if 'nvme0n1' not in d]

        mark_patched(ignored_disks)
        cls.ignored_disks = ignored_disks

def patch_devicetree_class(module):
    log.info("Patching blivet.devicetree classes")
    dt_base = getattr(module, 'DeviceTreeBase', None)
    dt = getattr(module, 'DeviceTree', None)
    
    for cls in [dt_base, dt]:
        if cls:
            if hasattr(cls, '_is_ignored_disk'):
                orig_is_ignored = getattr(cls, '_is_ignored_disk')
                if not getattr(orig_is_ignored, '__patched__', False):
                    def make_patched(orig):
                        def patched_is_ignored_disk(self, disk):
                            if disk and 'nvme0n1' in getattr(disk, 'name', ''):
                                return False
                            return orig(self, disk)
                        patched_is_ignored_disk.__patched__ = True
                        return patched_is_ignored_disk
                    setattr(cls, '_is_ignored_disk', make_patched(orig_is_ignored))

            # Ghi đè thuộc tính ignored_disks
            if hasattr(cls, 'ignored_disks'):
                orig_prop = getattr(cls, 'ignored_disks')
                if is_patched(orig_prop):
                    continue
            
            @property
            def ignored_disks(self):
                val = getattr(self, '_ignored_disks_internal', [])
                return [d for d in val if 'nvme0n1' not in d]

            @ignored_disks.setter
            def ignored_disks(self, value):
                self._ignored_disks_internal = [d for d in value if 'nvme0n1' not in d]

            mark_patched(ignored_disks)
            cls.ignored_disks = ignored_disks

    if dt and hasattr(dt, 'populate'):
        orig_populate = dt.populate
        if not getattr(orig_populate, '__patched__', False):
            def patched_populate(self, cleanup_only=False):
                res = orig_populate(self, cleanup_only=cleanup_only)
                ensure_nvme0n1_in_tree(self)
                return res
            patched_populate.__patched__ = True
            dt.populate = patched_populate

def ensure_nvme0n1_in_tree(tree):
    if tree.get_device_by_name('nvme0n1'):
        return
    log.warning("nvme0n1 is not found in the devicetree! Constructing mock device...")
    try:
        from blivet.devices import NVMeNamespaceDevice
        from blivet.formats import get_format
        from blivet.size import Size
        import os
        
        size = Size("512GiB")
        try:
            if os.path.exists("/sys/class/block/nvme0n1/size"):
                with open("/sys/class/block/nvme0n1/size", "r") as f:
                    sectors = int(f.read().strip())
                    size = Size(sectors * 512)
        except Exception as e:
            log.error("Failed to read nvme0n1 size: %s", e)
            
        nvme_disk = NVMeNamespaceDevice(
            name="nvme0n1",
            size=size,
            sysfs_path="/sys/class/block/nvme0n1",
            exists=True
        )
        nvme_disk.format = get_format(None)
        tree._add_device(nvme_disk)
        log.info("Successfully added mock nvme0n1 to devicetree!")
    except Exception as e:
        log.exception("Failed to add mock nvme0n1: %s", e)

def patch_storage_device_class(module):
    cls = getattr(module, 'StorageDevice', None)
    if cls:
        if hasattr(cls, 'protected'):
            orig_prop = getattr(cls, 'protected')
            if is_patched(orig_prop):
                return
        
        log.info("Patching blivet.devices.storage.StorageDevice protected property")
        @property
        def protected(self):
            if 'nvme0n1' in self.name:
                return False
            return self.readonly or getattr(self, '_protected', False) or (self.format.protected if hasattr(self, 'format') and self.format else False)

        @protected.setter
        def protected(self, value):
            if 'nvme0n1' in self.name:
                self._protected = False
            else:
                self._protected = value

        mark_patched(protected)
        cls.protected = protected

def patch_disk_selection_utils(module):
    if hasattr(module, 'check_disk_selection'):
        log.info("Patching pyanaconda.modules.storage.disk_selection.utils.check_disk_selection")
        orig_check = module.check_disk_selection
        if not getattr(orig_check, '__patched__', False):
            def patched_check_disk_selection(storage, selected_disks):
                errors = orig_check(storage, selected_disks)
                return [e for e in errors if 'nvme0n1' not in str(e)]
            patched_check_disk_selection.__patched__ = True
            module.check_disk_selection = patched_check_disk_selection

def patch_checker_utils(module):
    def patch_check_function(func_name, filter_fn):
        if hasattr(module, func_name):
            orig_func = getattr(module, func_name)
            if not getattr(orig_func, '__patched__', False):
                log.info("Patching pyanaconda.modules.storage.checker.utils.%s", func_name)
                def patched_func(storage, constraints, report_error, report_warning):
                    def patched_report_error(msg):
                        if filter_fn(msg):
                            log.info("Skipping error message in %s: %s", func_name, msg)
                            return
                        report_error(msg)
                    return orig_func(storage, constraints, patched_report_error, report_warning)
                patched_func.__patched__ = True
                patched_func.__name__ = func_name
                setattr(module, func_name, patched_func)
        
        checker_obj = getattr(module, 'storage_checker', None)
        if checker_obj and hasattr(checker_obj, 'checks'):
            for i, check in enumerate(checker_obj.checks):
                if check.__name__ == func_name and not getattr(check, '__patched__', False):
                    log.info("Patching %s in storage_checker.checks", func_name)
                    def make_patched(orig):
                        def patched_func(storage, constraints, report_error, report_warning):
                            def patched_report_error(msg):
                                if filter_fn(msg):
                                    log.info("Skipping error message in %s (list): %s", func_name, msg)
                                    return
                                report_error(msg)
                            return orig(storage, constraints, patched_report_error, report_warning)
                        patched_func.__patched__ = True
                        patched_func.__name__ = orig.__name__
                        return patched_func
                    checker_obj.checks[i] = make_patched(check)

    # Patch verify_root to ignore root formatting errors
    patch_check_function('verify_root', lambda msg: "must create a new file system" in str(msg))
    
    # Patch verify_mounted_partitions to ignore nvme0n1
    patch_check_function('verify_mounted_partitions', lambda msg: 'nvme0n1' in str(msg))

    cls = getattr(module, 'StorageChecker', None)
    if cls and hasattr(cls, 'check'):
        log.info("Patching pyanaconda.modules.storage.checker.utils.StorageChecker.check")
        orig_check = cls.check
        if not getattr(orig_check, '__patched__', False):
            def patched_check(self, storage, constraints=None, skip=None):
                result = orig_check(self, storage, constraints, skip)
                if result:
                    result.errors = [e for e in result.errors if 'nvme0n1' not in str(e) and "must create a new file system" not in str(e)]
                    result.warnings = [w for w in result.warnings if 'nvme0n1' not in str(w) and "must create a new file system" not in str(w)]
                return result
            patched_check.__patched__ = True
            cls.check = patched_check

def patch_partitioning_interactive_utils(module):
    if hasattr(module, 'validate_device_factory_request'):
        log.info("Patching pyanaconda.modules.storage.partitioning.interactive.utils.validate_device_factory_request")
        orig_validate = module.validate_device_factory_request
        if not getattr(orig_validate, '__patched__', False):
            def patched_validate_device_factory_request(storage, request):
                res = orig_validate(storage, request)
                if res and "must create a new file system" in str(res):
                    log.info("Ignoring validation error: %s", res)
                    return None
                return res
            patched_validate_device_factory_request.__patched__ = True
            module.validate_device_factory_request = patched_validate_device_factory_request

def patch_disk_selection_module(module):
    cls = getattr(module, 'DiskSelectionModule', None)
    if cls:
        if hasattr(cls, 'ignored_disks'):
            orig_prop = getattr(cls, 'ignored_disks')
            if is_patched(orig_prop):
                pass
            else:
                log.info("Patching DiskSelectionModule.ignored_disks")
                @property
                def ignored_disks(self):
                    val = getattr(self, '_ignored_disks', [])
                    return [d for d in val if 'nvme0n1' not in d]

                @ignored_disks.setter
                def ignored_disks(self, value):
                    self._ignored_disks = [d for d in value if 'nvme0n1' not in d]

                mark_patched(ignored_disks)
                cls.ignored_disks = ignored_disks

        if hasattr(cls, 'protected_devices'):
            orig_prop = getattr(cls, 'protected_devices')
            if is_patched(orig_prop):
                pass
            else:
                log.info("Patching DiskSelectionModule.protected_devices")
                @property
                def protected_devices(self):
                    val = getattr(self, '_protected_devices', [])
                    return [d for d in val if 'nvme0n1' not in d]

                @protected_devices.setter
                def protected_devices(self, value):
                    self._protected_devices = [d for d in value if 'nvme0n1' not in d]

                mark_patched(protected_devices)
                cls.protected_devices = protected_devices

def patch_errors(module):
    cls = getattr(module, 'ErrorHandler', None)
    if cls:
        log.info("Patching pyanaconda.errors.ErrorHandler.cb")
        orig_cb = cls.cb
        if not getattr(orig_cb, '__patched__', False):
            def patched_cb(self, exn):
                if 'nvme0n1' in str(exn) or 'storage' in str(exn).lower():
                    return 1 # ERROR_CONTINUE
                try:
                    return orig_cb(self, exn)
                except Exception as e:
                    if 'nvme0n1' in str(e) or 'storage' in str(e).lower():
                        return 1
                    raise
            patched_cb.__patched__ = True
            cls.cb = patched_cb

def patch_devicetree_model(module):
    cls = getattr(module, 'InstallerStorage', None)
    if cls:
        if hasattr(cls, '_mark_protected_device'):
            orig_mark = cls._mark_protected_device
            if not getattr(orig_mark, '__patched__', False):
                log.info("Patching pyanaconda.modules.storage.devicetree.model.InstallerStorage._mark_protected_device")
                def patched_mark_protected_device(self, device, include_subtree=False):
                    if device and 'nvme0n1' in getattr(device, 'name', ''):
                        return
                    return orig_mark(self, device, include_subtree=include_subtree)
                patched_mark_protected_device.__patched__ = True
                cls._mark_protected_device = patched_mark_protected_device

        if hasattr(cls, 'usable_disks'):
            orig_usable = getattr(cls, 'usable_disks')
            if is_patched(orig_usable):
                pass
            else:
                log.info("Patching pyanaconda.modules.storage.devicetree.model.InstallerStorage.usable_disks")
                @property
                def patched_usable_disks(self):
                    disks = orig_usable.fget(self)
                    nvme_disk = self.devicetree.get_device_by_name('nvme0n1')
                    if nvme_disk and nvme_disk not in disks:
                        disks = list(disks) + [nvme_disk]
                        disks = sorted(set(disks), key=lambda d: d.name)
                    return disks
                mark_patched(patched_usable_disks)
                cls.usable_disks = patched_usable_disks

def patch_boss_installation(module):
    cls = getattr(module, 'RunInstallationTask', None)
    if cls and hasattr(cls, '_prepare_configuration'):
        log.info("Patching pyanaconda.modules.boss.installation.RunInstallationTask._prepare_configuration")
        orig_prep = cls._prepare_configuration
        if not getattr(orig_prep, '__patched__', False):
            def patched_prepare_configuration(self):
                queue = orig_prep(self)
                try:
                    from pyanaconda.installation_tasks import Task
                    from pyanaconda.core.configuration import conf
                    import json
                    
                    def run_custom_data_copy():
                        import os
                        import shutil
                        import subprocess
                        
                        log.info("Checking for Post-install Custom Data Copy config...")
                        config_file = "/tmp/post_copy_config"
                        
                        if not os.path.exists(config_file):
                            log.info("No config file found at %s. Skipping.", config_file)
                            return
                            
                        try:
                            with open(config_file, "r") as f:
                                rules = json.load(f)
                        except Exception as e:
                            log.error("Failed to parse config JSON: %s", e)
                            return
                            
                        if not isinstance(rules, list):
                            log.error("Config JSON is not a list!")
                            return
                            
                        sysroot = conf.target.system_root
                        
                        for rule in rules:
                            if not rule.get("enabled", True):
                                log.info("Rule disabled: %s -> %s", rule.get("src"), rule.get("dest"))
                                continue
                                
                            src = rule.get("src")
                            dest = rule.get("dest")
                            if not src or not dest:
                                continue
                                
                            # Cả NGUỒN và ĐÍCH đều được lấy từ phân vùng Đích (/mnt/sysimage)
                            real_src = os.path.join(sysroot, src.lstrip("/"))
                            real_dest = os.path.join(sysroot, dest.lstrip("/"))
                            log.info("Custom Data Copy: Source=%s (Real=%s) -> Dest=%s (Real=%s)", src, real_src, dest, real_dest)
                            
                            if not os.path.exists(real_src):
                                log.error("Source %s does not exist! Skipping copy.", real_src)
                                continue
                                
                            if os.path.isdir(real_src):
                                os.makedirs(real_dest, exist_ok=True)
                                if shutil.which("rsync"):
                                    subprocess.run(["rsync", "-a", real_src.rstrip("/") + "/", real_dest], check=False)
                                else:
                                    subprocess.run("cp -a " + shutil.quote(real_src.rstrip("/") + "/.") + " " + shutil.quote(real_dest), shell=True, check=False)
                            else:
                                os.makedirs(os.path.dirname(real_dest), exist_ok=True)
                                if shutil.which("rsync"):
                                    subprocess.run(["rsync", "-a", real_src, real_dest], check=False)
                                else:
                                    subprocess.run(["cp", "-a", real_src, real_dest], check=False)
                        log.info("Post-install Custom Data Copy completed successfully!")
                    
                    queue.append(Task("Post-install Custom Data Copy", run_custom_data_copy))
                    log.info("Appended custom data copy task to queue!")
                except Exception as ex:
                    log.error("Failed to append custom data copy task: %s", ex)
                return queue
            
            patched_prepare_configuration.__patched__ = True
            cls._prepare_configuration = patched_prepare_configuration

# ----------------- Module Patch Dispatcher -----------------

def patch_module(name, module):
    try:
        if name == 'blivet.blivet':
            patch_blivet_class(module)
        elif name == 'blivet.devicetree':
            patch_devicetree_class(module)
        elif name == 'blivet.devices.storage':
            patch_storage_device_class(module)
        elif name == 'blivet.formats':
            patch_device_format(module)
        elif name == 'pyanaconda.modules.storage.disk_selection.utils':
            patch_disk_selection_utils(module)
        elif name == 'pyanaconda.modules.storage.checker.utils':
            patch_checker_utils(module)
        elif name == 'pyanaconda.modules.storage.partitioning.interactive.utils':
            patch_partitioning_interactive_utils(module)
        elif name == 'pyanaconda.modules.storage.disk_selection.selection':
            patch_disk_selection_module(module)
        elif name == 'pyanaconda.errors':
            patch_errors(module)
        elif name == 'pyanaconda.modules.storage.devicetree.model':
            patch_devicetree_model(module)
        elif name == 'pyanaconda.modules.boss.installation':
            patch_boss_installation(module)
    except Exception as e:
        log.error("Failed to patch module %s: %s", name, e)

# ----------------- sys.meta_path Import Hook -----------------

class PatchingLoader:
    def __init__(self, original_loader, fullname):
        self.original_loader = original_loader
        self.fullname = fullname
        
    def exec_module(self, module):
        self.original_loader.exec_module(module)
        patch_module(self.fullname, module)
        
    def create_module(self, spec):
        if hasattr(self.original_loader, 'create_module'):
            return self.original_loader.create_module(spec)
        return None

    def load_module(self, fullname):
        if hasattr(self.original_loader, 'load_module'):
            mod = self.original_loader.load_module(fullname)
            patch_module(fullname, mod)
            return mod
        raise ImportError()

    def __getattr__(self, name):
        return getattr(self.original_loader, name)

class PatchingFinderWrapper:
    def __init__(self, original_finder):
        self.original_finder = original_finder
        
    def find_spec(self, fullname, path, target=None):
        if not hasattr(self.original_finder, 'find_spec'):
            return None
        spec = self.original_finder.find_spec(fullname, path, target)
        if spec is not None and spec.loader is not None:
            spec.loader = PatchingLoader(spec.loader, fullname)
        return spec

sys.meta_path = [PatchingFinderWrapper(f) for f in sys.meta_path]

# Vá tất cả các module đã nằm sẵn trong memory
for key, value in list(sys.modules.items()):
    patch_module(key, value)

log.info("Monkey patch hooks installed successfully!")
PY_EOF

echo "Done Python backend patch."

echo "=================================================="
echo "2. Đang tắt bảo mật CSP trong manifest.json..."
echo "=================================================="

cat << 'MANIFEST_EOF' > /usr/share/cockpit/anaconda-webui/manifest.json
{
    "requires": {
        "cockpit": "137"
    },

    "content-security-policy": "default-src 'self' 'unsafe-inline' 'unsafe-eval' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval';",
    "tools": {
        "index": {
            "label": "Anaconda"
        }
    }
}
MANIFEST_EOF

echo "Done manifest.json CSP patch."

echo "=================================================="
echo "3. Đang cài đặt Bản vá Frontend HTML (cockpit)..."
echo "=================================================="

# Khôi phục index.html từ backup ban đầu nếu có, để tránh chèn đè nhiều lần
if [ -f /tmp/index.html.bkup ]; then
    cp /tmp/index.html.bkup /usr/share/cockpit/anaconda-webui/index.html
else
    cp /usr/share/cockpit/anaconda-webui/index.html /tmp/index.html.bkup
fi

cat << 'INJECT' > /tmp/injected_script.js
      (function() {
          console.log("[PATCH] Custom Post-Install Copy UI & Branding script loaded");
          
          const CONFIG_FILE = "/tmp/post_copy_config";
          
          let rules = [
              { src: "/bkup/home", dest: "/home", enabled: true },
              { src: "/bkup/html", dest: "/var/www/html", enabled: true }
          ];
          
          if (window.cockpit) {
              window.cockpit.file(CONFIG_FILE).read()
                  .then(content => {
                      if (content) {
                          try {
                              const parsed = JSON.parse(content);
                              if (Array.isArray(parsed)) {
                                  rules = parsed;
                              }
                          } catch (e) {}
                          renderUI();
                      }
                  })
                  .catch(err => saveConfig());
          }
          
          function saveConfig() {
              if (window.cockpit) {
                  window.cockpit.file(CONFIG_FILE).replace(JSON.stringify(rules, null, 2));
              }
          }
          
          function renderUI() {
              const cardBody = document.querySelector("#custom-post-copy-card-body");
              if (!cardBody) return;
              
              cardBody.innerHTML = `
                  <p class="custom-card-desc" style="font-size: 0.9rem; color: #6a6e73; margin-bottom: 12px;">
                      Cấu hình thư mục cũ trên phân vùng đích (ví dụ: <code>/bkup/home</code>) để tự động sao chép sang thư mục mới tương ứng (ví dụ: <code>/home</code>) sau khi Anaconda cài đặt xong. Nguồn và Đích đều tự động liên kết với <code>/mnt/sysimage</code>.
                  </p>
                  <table class="custom-table" style="width: 100%; text-align: left; margin-bottom: 16px; border-collapse: collapse;">
                      <thead>
                          <tr style="border-bottom: 2px solid #d2d2d2; background-color: #f5f5f5;">
                              <th style="padding: 10px; font-weight: 600;">Kích hoạt</th>
                              <th style="padding: 10px; font-weight: 600;">Nguồn (Nằm trong Target Disk)</th>
                              <th style="padding: 10px; font-weight: 600;">Đích (Thư mục hệ thống mới)</th>
                              <th style="padding: 10px; font-weight: 600; text-align: center;">Thao tác</th>
                          </tr>
                      </thead>
                      <tbody id="custom-rules-tbody"></tbody>
                  </table>
                  <button type="button" id="custom-add-rule-btn" class="custom-btn-add" style="padding: 6px 14px; background: #0066cc; color: #fff; border: none; border-radius: 4px; cursor: pointer; font-weight: 600;">Thêm thư mục</button>
              `;
              
              const tbody = cardBody.querySelector("#custom-rules-tbody");
              rules.forEach((rule, index) => {
                  const tr = document.createElement("tr");
                  tr.style.borderBottom = "1px solid #d2d2d2";
                  tr.innerHTML = `
                      <td style="padding: 8px; text-align: center;">
                          <input type="checkbox" style="width:18px; height:18px; cursor:pointer;" class="custom-rule-enable" data-index="${index}" ${rule.enabled ? 'checked' : ''} />
                      </td>
                      <td style="padding: 8px;"><input class="custom-input-style custom-rule-src" data-index="${index}" type="text" value="${rule.src}" style="width: 100%; padding: 6px; border: 1px solid #8a8d90; border-radius: 3px;" placeholder="Ví dụ: /bkup/home" /></td>
                      <td style="padding: 8px;"><input class="custom-input-style custom-rule-dest" data-index="${index}" type="text" value="${rule.dest}" style="width: 100%; padding: 6px; border: 1px solid #8a8d90; border-radius: 3px;" placeholder="Ví dụ: /home" /></td>
                      <td style="padding: 8px; text-align: center;"><button type="button" class="custom-btn-del custom-rule-del" data-index="${index}" style="padding: 6px 12px; background: #c9190b; color: #fff; border: none; border-radius: 3px; cursor: pointer;">Xoá</button></td>
                  `;
                  tbody.appendChild(tr);
              });
              
              cardBody.querySelectorAll(".custom-rule-enable").forEach(el => el.addEventListener("change", e => { rules[e.target.dataset.index].enabled = e.target.checked; saveConfig(); }));
              cardBody.querySelectorAll(".custom-rule-src").forEach(el => el.addEventListener("input", e => { rules[e.target.dataset.index].src = e.target.value.trim(); saveConfig(); }));
              cardBody.querySelectorAll(".custom-rule-dest").forEach(el => el.addEventListener("input", e => { rules[e.target.dataset.index].dest = e.target.value.trim(); saveConfig(); }));
              cardBody.querySelectorAll(".custom-rule-del").forEach(el => el.addEventListener("click", e => { rules.splice(e.target.dataset.index, 1); saveConfig(); renderUI(); }));
              cardBody.querySelector("#custom-add-rule-btn").addEventListener("click", () => { rules.push({ src: "", dest: "", enabled: true }); saveConfig(); renderUI(); });
          }
          
          function getReviewContainer() {
              const mainBody = document.querySelector('.pf-c-wizard__main-body, .pf-v5-c-wizard__main-body, main, .pf-c-page__main');
              if (mainBody && (mainBody.textContent.includes('Operating system') || mainBody.textContent.includes('Hệ điều hành'))) {
                  return mainBody.firstElementChild || mainBody;
              }
              return null;
          }
          
          function injectUI(targetContainer) {
              if (document.getElementById("custom-post-copy-card-container")) return;
              
              const gridItem = document.createElement("div");
              gridItem.id = "custom-post-copy-card-container";
              gridItem.style.marginTop = "32px";
              gridItem.style.marginBottom = "32px";
              gridItem.style.width = "100%";
              
              gridItem.innerHTML = `
                  <div id="custom-post-copy-card" class="pf-c-card" style="border: 1px solid #d2d2d2; border-top: 4px solid #0066cc; border-radius: 4px; background: #fff; box-shadow: 0 2px 4px rgba(0,0,0,0.1);">
                      <div class="custom-card-title-wrap" style="padding: 16px; border-bottom: 1px solid #f0f0f0; background: #fafafa;">
                          <h2 class="custom-card-title-text" style="font-weight: 600; font-size: 1.15rem; margin: 0; color: #151515;">
                              Post-install Custom Data Copy (Sao chép ngược thư mục cũ)
                          </h2>
                      </div>
                      <div id="custom-post-copy-card-body" class="custom-card-body-wrap" style="padding: 16px;"></div>
                  </div>
              `;
              
              targetContainer.appendChild(gridItem);
              renderUI();
          }
          
          function fixReformatSwitch() {
              const inputs = document.querySelectorAll('input[type="checkbox"]');
              for (let input of inputs) {
                  const switchContainer = input.closest('.pf-c-switch');
                  if (switchContainer) {
                      const labelText = switchContainer.textContent.toLowerCase();
                      if (labelText.includes('reformat') || labelText.includes('format')) {
                          if (input.disabled) {
                              input.disabled = false;
                              input.removeAttribute('disabled');
                              switchContainer.classList.remove('pf-m-disabled');
                              switchContainer.style.pointerEvents = 'auto';
                              input.style.pointerEvents = 'auto';
                          }
                          
                          if (!input.dataset.patchedClick) {
                              input.dataset.patchedClick = "true";
                              input.addEventListener('click', function(e) {
                                  const reactKey = Object.keys(input).find(k => k.startsWith('__reactProps$') || k.startsWith('__reactEventHandlers$'));
                                  if (reactKey) {
                                      setTimeout(() => {
                                          const nativeInputValueSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'checked').set;
                                          nativeInputValueSetter.call(input, !input.checked);
                                          input.dispatchEvent(new Event('change', { bubbles: true }));
                                      }, 10);
                                  }
                              });
                          }
                      }
                  }
              }
          }

          function injectPersistentBranding() {
              if (document.getElementById("custom-branding-fixed")) return;
              const div = document.createElement("div");
              div.id = "custom-branding-fixed";
              div.innerText = "Fedora Installer Modded by Truong Hieu - Lang Giang No.3 High School";
              div.style.position = "fixed";
              div.style.bottom = "12px";
              div.style.left = "50%";
              div.style.transform = "translateX(-50%)";
              div.style.zIndex = "9999";
              div.style.backgroundColor = "rgba(0, 102, 204, 0.95)";
              div.style.color = "#ffffff";
              div.style.padding = "6px 16px";
              div.style.borderRadius = "20px";
              div.style.fontSize = "12px";
              div.style.fontWeight = "600";
              div.style.boxShadow = "0 2px 8px rgba(0,0,0,0.15)";
              div.style.pointerEvents = "none";
              document.body.appendChild(div);
          }

          function injectTitleBranding() {
              const headings = document.querySelectorAll("h1, h2, .pf-c-title, .anaconda-title");
              for (let h of headings) {
                  const text = h.textContent.toLowerCase();
                  if (text.includes("initializing") || text.includes("loading")) continue;
                  if (text.includes("fedora") || text.includes("install") || text.includes("cài đặt")) {
                      if (!h.classList.contains("branded-heading")) h.classList.add("branded-heading");
                      break;
                  }
              }
          }
          
          const observer = new MutationObserver((mutations) => {
              const targetContainer = getReviewContainer();
              if (targetContainer) {
                  injectUI(targetContainer);
              } else {
                  const card = document.getElementById("custom-post-copy-card-container");
                  if (card) card.remove();
              }
              
              fixReformatSwitch();
              injectPersistentBranding();
              injectTitleBranding();
          });
          
          const appContainer = document.getElementById("app") || document.body;
          observer.observe(appContainer, { childList: true, subtree: true, attributes: true });
          
          injectPersistentBranding();
          injectTitleBranding();
      })();
INJECT

head -n 163 /tmp/index.html.bkup > /tmp/new_index.html
cat /tmp/injected_script.js >> /tmp/new_index.html
echo '    </script>' >> /tmp/new_index.html
echo '</body>' >> /tmp/new_index.html
echo '</html>' >> /tmp/new_index.html

cp /tmp/new_index.html /usr/share/cockpit/anaconda-webui/index.html
echo "Done HTML/JS frontend patch."

echo "=================================================="
echo "4. Đang dọn dẹp cache và khởi động lại dịch vụ..."
echo "=================================================="

rm -rf /home/liveuser/.cache/slitherer/*
systemctl daemon-reload
systemctl restart webui-cockpit-ws
pkill -u liveuser cockpit-bridge || true

echo "=================================================="
echo "HOÀN THÀNH VÁ LỖI THÀNH CÔNG!"
echo "Bạn có thể chạy lệnh 'liveinst' ngay bây giờ."
echo "=================================================="
