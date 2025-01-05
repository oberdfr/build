#!/usr/bin/env python3

import os
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
import argparse
from collections import defaultdict
import threading

class ModuleAnalyzer:
    def __init__(self, modules_dir: str, max_workers: int = None):
        self.modules_dir = modules_dir
        self.max_workers = max_workers or os.cpu_count()
        self.deps_cache = {}
        self.cache_lock = threading.Lock()
        self.dependency_graph = defaultdict(set)
        
    def get_module_files(self):
        """Get list of all .ko files in the modules directory."""
        return [f for f in os.listdir(self.modules_dir) if f.endswith('.ko')]

    def get_direct_dependencies(self, module):
        """Get direct dependencies using modinfo."""
        if module in self.deps_cache:
            return self.deps_cache[module]

        module_path = os.path.join(self.modules_dir, module)
        try:
            result = subprocess.run(['modinfo', '-F', 'depends', module_path], 
                                 capture_output=True, text=True)
            deps = set()
            if result.stdout.strip():
                for dep in result.stdout.split(','):
                    dep = dep.strip()
                    if dep and os.path.exists(os.path.join(self.modules_dir, f"{dep}.ko")):
                        deps.add(f"{dep}.ko")

            with self.cache_lock:
                self.deps_cache[module] = deps
            return deps

        except subprocess.CalledProcessError:
            with self.cache_lock:
                self.deps_cache[module] = set()
            return set()

    def build_dependency_graph(self):
        """Build the complete dependency graph."""
        modules = self.get_module_files()
        
        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            future_to_module = {
                executor.submit(self.get_direct_dependencies, module): module 
                for module in modules
            }
            
            for future in as_completed(future_to_module):
                module = future_to_module[future]
                direct_deps = future.result()
                self.dependency_graph[module] = direct_deps

    def get_all_dependencies(self, module, visited=None):
        """Get all dependencies recursively, avoiding cycles."""
        if visited is None:
            visited = set()
        
        if module in visited:
            return set()
        
        visited.add(module)
        all_deps = self.dependency_graph[module].copy()
        
        for dep in self.dependency_graph[module]:
            if dep not in visited:  # Only recurse if not visited
                indirect_deps = self.get_all_dependencies(dep, visited)
                all_deps.update(indirect_deps)
            
        return all_deps

    def generate_modules_dep(self):
        """Generate the complete modules.dep content."""
        print("Building dependency graph...")
        self.build_dependency_graph()
        
        print("Resolving dependencies...")
        output_lines = []
        
        for module in sorted(self.get_module_files()):
            deps = self.get_all_dependencies(module)
            if deps:
                # Create properly formatted dependency line
                dep_paths = [f"/lib/modules/{dep}" for dep in sorted(deps)]
                output_lines.append(f"/lib/modules/{module}: {' '.join(dep_paths)}")
            else:
                output_lines.append(f"/lib/modules/{module}:")

        return "\n".join(output_lines)

def main():
    parser = argparse.ArgumentParser(description='Fast module dependency generator')
    parser.add_argument('modules_dir', help='Directory containing kernel modules')
    parser.add_argument('--output', '-o', help='Output file (default: modules.dep)',
                      default='modules.dep')
    parser.add_argument('--jobs', '-j', type=int, help='Number of worker threads',
                      default=os.cpu_count())
    
    args = parser.parse_args()
    
    analyzer = ModuleAnalyzer(args.modules_dir, args.jobs)
    deps_content = analyzer.generate_modules_dep()
    
    with open(args.output, 'w') as f:
        f.write(deps_content)
    
    print(f"Dependencies written to {args.output}")

if __name__ == '__main__':
    main()