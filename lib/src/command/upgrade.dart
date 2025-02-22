// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml_edit/yaml_edit.dart';

import '../command.dart';
import '../command_runner.dart';
import '../entrypoint.dart';
import '../exceptions.dart';
import '../io.dart';
import '../log.dart' as log;
import '../null_safety_analysis.dart';
import '../package.dart';
import '../package_name.dart';
import '../pubspec.dart';
import '../pubspec_utils.dart';
import '../solver.dart';
import '../source/hosted.dart';

/// Handles the `upgrade` pub command.
class UpgradeCommand extends PubCommand {
  @override
  String get name => 'upgrade';
  @override
  String get description =>
      "Upgrade the current package's dependencies to latest versions.";
  @override
  String get argumentsDescription => '[dependencies...]';
  @override
  String get docUrl => 'https://dart.dev/tools/pub/cmd/pub-upgrade';

  @override
  bool get isOffline => argResults['offline'];

  UpgradeCommand() {
    argParser.addFlag('offline',
        help: 'Use cached packages instead of accessing the network.');

    argParser.addFlag('dry-run',
        abbr: 'n',
        negatable: false,
        help: "Report what dependencies would change but don't change any.");

    argParser.addFlag('precompile',
        help: 'Precompile executables in immediate dependencies.');

    argParser.addFlag('null-safety',
        negatable: false,
        help: 'Upgrade constraints in pubspec.yaml to null-safety versions');
    argParser.addFlag('nullsafety', negatable: false, hide: true);

    argParser.addFlag('packages-dir', hide: true);

    argParser.addFlag('legacy-packages-file',
        help: 'Generate the legacy ".packages" file', negatable: false);

    argParser.addFlag(
      'major-versions',
      help: 'Upgrades packages to their latest resolvable versions, '
          'and updates pubspec.yaml.',
      negatable: false,
    );

    argParser.addFlag(
      'example',
      help: 'Also run in `example/` (if it exists).',
      hide: true,
    );

    argParser.addOption('directory',
        abbr: 'C', help: 'Run this in the directory<dir>.', valueHelp: 'dir');
  }

  /// Avoid showing spinning progress messages when not in a terminal.
  bool get _shouldShowSpinner => stdout.hasTerminal;

  bool get _dryRun => argResults['dry-run'];

  bool get _precompile => argResults['precompile'];

  bool get _packagesFile => argResults['legacy-packages-file'];

  bool get _upgradeNullSafety =>
      argResults['nullsafety'] || argResults['null-safety'];

  bool get _upgradeMajorVersions => argResults['major-versions'];

  @override
  Future<void> runProtected() async {
    if (argResults.wasParsed('packages-dir')) {
      log.warning(log.yellow(
          'The --packages-dir flag is no longer used and does nothing.'));
    }

    if (_upgradeNullSafety && _upgradeMajorVersions) {
      usageException('--major-versions and --null-safety cannot be combined');
    }

    if (_upgradeNullSafety) {
      if (argResults['example'] && entrypoint.example != null) {
        log.warning(
            'Running `upgrade --null-safety` only in `${entrypoint.root.dir}`. Run `$topLevelProgram pub upgrade --null-safety --directory example/` separately.');
      }
      await _runUpgradeNullSafety();
    } else if (_upgradeMajorVersions) {
      if (argResults['example'] && entrypoint.example != null) {
        log.warning(
            'Running `upgrade --major-versions` only in `${entrypoint.root.dir}`. Run `$topLevelProgram pub upgrade --major-versions --directory example/` separately.');
      }
      await _runUpgradeMajorVersions();
    } else {
      await _runUpgrade(entrypoint);
    }
    if (argResults['example'] && entrypoint.example != null) {
      // Reload the entrypoint to ensure we pick up potential changes that has
      // been made.
      final exampleEntrypoint = Entrypoint(directory, cache).example!;
      await _runUpgrade(exampleEntrypoint, onlySummary: true);
    }
  }

  Future<void> _runUpgrade(Entrypoint e, {bool onlySummary = false}) async {
    await e.acquireDependencies(
      SolveType.upgrade,
      unlock: argResults.rest,
      dryRun: _dryRun,
      precompile: _precompile,
      onlyReportSuccessOrFailure: onlySummary,
      generateDotPackages: _packagesFile,
      analytics: analytics,
    );
    _showOfflineWarning();
  }

  /// Return names of packages to be upgraded, and throws [UsageException] if
  /// any package names not in the direct dependencies or dev_dependencies are given.
  ///
  /// This assumes that either `--major-versions` or `--null-safety` was passed.
  List<String> _directDependenciesToUpgrade() {
    assert(_upgradeNullSafety || _upgradeMajorVersions);

    final directDeps = [
      ...entrypoint.root.pubspec.dependencies.keys,
      ...entrypoint.root.pubspec.devDependencies.keys
    ];
    final toUpgrade = argResults.rest.isEmpty ? directDeps : argResults.rest;

    // Check that all package names in upgradeOnly are direct-dependencies
    final notInDeps = toUpgrade.where((n) => !directDeps.contains(n));
    if (toUpgrade.any(notInDeps.contains)) {
      var modeFlag = '';
      if (_upgradeNullSafety) {
        modeFlag = '--null-safety';
      }
      if (_upgradeMajorVersions) {
        modeFlag = '--major-versions';
      }

      usageException('''
Dependencies specified in `$topLevelProgram pub upgrade $modeFlag <dependencies>` must
be direct 'dependencies' or 'dev_dependencies', following packages are not:
 - ${notInDeps.join('\n - ')}

''');
    }

    return toUpgrade;
  }

  Future<void> _runUpgradeMajorVersions() async {
    final toUpgrade = _directDependenciesToUpgrade();

    final resolvablePubspec = stripVersionUpperBounds(
      entrypoint.root.pubspec,
      stripOnly: toUpgrade,
    );

    // Solve [resolvablePubspec] in-memory and consolidate the resolved
    // versions of the packages into a map for quick searching.
    final resolvedPackages = <String, PackageId>{};
    final solveResult = await log.spinner('Resolving dependencies', () async {
      return await resolveVersions(
        SolveType.upgrade,
        cache,
        Package.inMemory(resolvablePubspec),
      );
    }, condition: _shouldShowSpinner);
    for (final resolvedPackage in solveResult.packages) {
      resolvedPackages[resolvedPackage.name] = resolvedPackage;
    }

    // Changes to be made to `pubspec.yaml`.
    // Mapping from original to changed value.
    final changes = <PackageRange, PackageRange>{};
    final declaredHostedDependencies = [
      ...entrypoint.root.pubspec.dependencies.values,
      ...entrypoint.root.pubspec.devDependencies.values,
    ].where((dep) => dep.source is HostedSource);
    for (final dep in declaredHostedDependencies) {
      final resolvedPackage = resolvedPackages[dep.name]!;
      if (!toUpgrade.contains(dep.name)) {
        // If we're not to upgrade this package, or it wasn't in the
        // resolution somehow, then we ignore it.
        continue;
      }

      // Skip [dep] if it has a dependency_override.
      if (entrypoint.root.dependencyOverrides.containsKey(dep.name)) {
        continue;
      }

      if (dep.constraint.allowsAll(resolvedPackage.version)) {
        // If constraint allows the resolvable version we found, then there is
        // no need to update the `pubspec.yaml`
        continue;
      }

      changes[dep] = dep.toRef().withConstraint(
            VersionConstraint.compatibleWith(
              resolvedPackage.version,
            ),
          );
    }
    final newPubspecText = _updatePubspec(changes);

    if (_dryRun) {
      // Even if it is a dry run, run `acquireDependencies` so that the user
      // gets a report on changes.
      await Entrypoint.inMemory(
        Package.inMemory(
          Pubspec.parse(newPubspecText, cache.sources),
        ),
        cache,
        lockFile: entrypoint.lockFile,
        solveResult: solveResult,
      ).acquireDependencies(
        SolveType.get,
        dryRun: true,
        precompile: _precompile,
        analytics: null, // No analytics for dry-run
        generateDotPackages: false,
      );
    } else {
      if (changes.isNotEmpty) {
        writeTextFile(entrypoint.pubspecPath, newPubspecText);
      }
      // TODO: Allow Entrypoint to be created with in-memory pubspec, so that
      //       we can show the changes when not in --dry-run mode. For now we only show
      //       the changes made to pubspec.yaml in dry-run mode.
      await Entrypoint(directory, cache).acquireDependencies(
        SolveType.get,
        precompile: _precompile,
        analytics: analytics,
        generateDotPackages: argResults['legacy-packages-file'],
      );
    }

    _outputChangeSummary(changes);

    // If any of the packages to upgrade are dependency overrides, then we
    // show a warning.
    final toUpgradeOverrides =
        toUpgrade.where(entrypoint.root.dependencyOverrides.containsKey);
    if (toUpgradeOverrides.isNotEmpty) {
      log.warning(
        'Warning: dependency_overrides prevents upgrades for: '
        '${toUpgradeOverrides.join(', ')}',
      );
    }

    _showOfflineWarning();
  }

  Future<void> _runUpgradeNullSafety() async {
    final toUpgrade = _directDependenciesToUpgrade();

    final nullsafetyPubspec = await _upgradeToNullSafetyConstraints(
      entrypoint.root.pubspec,
      toUpgrade,
    );

    /// Solve [nullsafetyPubspec] in-memory and consolidate the resolved
    /// versions of the packages into a map for quick searching.
    final resolvedPackages = <String, PackageId>{};
    final solveResult = await log.spinner('Resolving dependencies', () async {
      return await resolveVersions(
        SolveType.upgrade,
        cache,
        Package.inMemory(nullsafetyPubspec),
      );
    }, condition: _shouldShowSpinner);
    for (final resolvedPackage in solveResult.packages) {
      resolvedPackages[resolvedPackage.name] = resolvedPackage;
    }

    /// Changes to be made to `pubspec.yaml`.
    /// Mapping from original to changed value.
    final changes = <PackageRange, PackageRange>{};
    final declaredHostedDependencies = [
      ...entrypoint.root.pubspec.dependencies.values,
      ...entrypoint.root.pubspec.devDependencies.values,
    ].where((dep) => dep.source is HostedSource);
    for (final dep in declaredHostedDependencies) {
      final resolvedPackage = resolvedPackages[dep.name]!;
      if (!toUpgrade.contains(dep.name)) {
        // If we're not to upgrade this package, or it wasn't in the
        // resolution somehow, then we ignore it.
        continue;
      }

      final constraint = VersionConstraint.compatibleWith(
        resolvedPackage.version,
      );
      if (dep.constraint.allowsAll(constraint) &&
          constraint.allowsAll(dep.constraint)) {
        // If constraint allows the same as the existing constraint then
        // there is no need to make changes.
        continue;
      }

      changes[dep] = dep.toRef().withConstraint(constraint);
    }

    final newPubspecText = _updatePubspec(changes);
    if (_dryRun) {
      // Even if it is a dry run, run `acquireDependencies` so that the user
      // gets a report on changes.
      // TODO(jonasfj): Stop abusing Entrypoint.global for dry-run output
      await Entrypoint.inMemory(
        Package.inMemory(Pubspec.parse(newPubspecText, cache.sources)),
        cache,
        lockFile: entrypoint.lockFile,
        solveResult: solveResult,
      ).acquireDependencies(
        SolveType.upgrade,
        dryRun: true,
        precompile: _precompile,
        analytics: null,
        generateDotPackages: false,
      );
    } else {
      if (changes.isNotEmpty) {
        writeTextFile(entrypoint.pubspecPath, newPubspecText);
      }
      // TODO: Allow Entrypoint to be created with in-memory pubspec, so that
      //       we can show the changes in --dry-run mode. For now we only show
      //       the changes made to pubspec.yaml in dry-run mode.
      await Entrypoint(directory, cache).acquireDependencies(
        SolveType.upgrade,
        precompile: _precompile,
        analytics: analytics,
        generateDotPackages: argResults['legacy-packages-file'],
      );
    }

    _outputChangeSummary(changes);

    // Warn if not all dependencies were migrated to a null-safety compatible
    // version. This can happen because:
    //  - `upgradeOnly` was given,
    //  - root has SDK dependencies,
    //  - root has git or path dependencies,
    //  - root has dependency_overrides
    final nonMigratedDirectDeps = <String>[];
    final directDeps = [
      ...entrypoint.root.pubspec.dependencies.keys,
      ...entrypoint.root.pubspec.devDependencies.keys
    ];
    await Future.wait(directDeps.map((name) async {
      final resolvedPackage = resolvedPackages[name]!;

      final pubspec = await cache.describe(resolvedPackage);
      if (!pubspec.languageVersion.supportsNullSafety) {
        nonMigratedDirectDeps.add(name);
      }
    }));
    if (nonMigratedDirectDeps.isNotEmpty) {
      log.warning('''
\nFollowing direct 'dependencies' and 'dev_dependencies' are not migrated to
null-safety yet:
 - ${nonMigratedDirectDeps.join('\n - ')}

You may have to:
 * Upgrade git and path dependencies manually,
 * Upgrade to a newer SDK for newer SDK dependencies,
 * Remove dependency_overrides, and/or,
 * Find other packages to use.
''');
    }

    _showOfflineWarning();
  }

  /// Updates `pubspec.yaml` with given [changes].
  String _updatePubspec(
    Map<PackageRange, PackageRange> changes,
  ) {
    ArgumentError.checkNotNull(changes, 'changes');

    final yamlEditor = YamlEditor(readTextFile(entrypoint.pubspecPath));
    final deps = entrypoint.root.pubspec.dependencies.keys;
    final devDeps = entrypoint.root.pubspec.devDependencies.keys;

    for (final change in changes.values) {
      if (deps.contains(change.name)) {
        yamlEditor.update(
          ['dependencies', change.name],
          // TODO(jonasfj): Fix support for third-party pub servers.
          change.constraint.toString(),
        );
      } else if (devDeps.contains(change.name)) {
        yamlEditor.update(
          ['dev_dependencies', change.name],
          // TODO: Fix support for third-party pub servers
          change.constraint.toString(),
        );
      }
    }
    return yamlEditor.toString();
  }

  /// Outputs a summary of changes made to `pubspec.yaml`.
  void _outputChangeSummary(
    Map<PackageRange, PackageRange> changes,
  ) {
    ArgumentError.checkNotNull(changes, 'changes');

    if (changes.isEmpty) {
      final wouldBe = _dryRun ? 'would be made to' : 'to';
      log.message('\nNo changes $wouldBe pubspec.yaml!');
    } else {
      final s = changes.length == 1 ? '' : 's';

      final changed = _dryRun ? 'Would change' : 'Changed';
      log.message('\n$changed ${changes.length} constraint$s in pubspec.yaml:');
      changes.forEach((from, to) {
        log.message('  ${from.name}: ${from.constraint} -> ${to.constraint}');
      });
    }
  }

  void _showOfflineWarning() {
    if (isOffline) {
      log.warning('Warning: Upgrading when offline may not update you to the '
          'latest versions of your dependencies.');
    }
  }

  /// Returns new pubspec with the same dependencies as [original], but with:
  ///  * the lower-bound of hosted package constraint set to first null-safety
  ///    compatible version, and,
  ///  * the upper-bound of hosted package constraints removed.
  ///
  /// Only changes listed in [upgradeOnly] will have their constraints touched.
  ///
  /// Throws [ApplicationException] if one of the dependencies does not have
  /// a null-safety compatible version.
  Future<Pubspec> _upgradeToNullSafetyConstraints(
    Pubspec original,
    List<String> upgradeOnly,
  ) async {
    ArgumentError.checkNotNull(original, 'original');
    ArgumentError.checkNotNull(upgradeOnly, 'upgradeOnly');

    final hasNoNullSafetyVersions = <String>{};
    final hasNullSafetyVersions = <String>{};

    Future<Iterable<PackageRange>> removeUpperConstraints(
      Iterable<PackageRange> dependencies,
    ) async =>
        await Future.wait(dependencies.map((dep) async {
          if (dep.source is! HostedSource) {
            return dep;
          }
          if (!upgradeOnly.contains(dep.name)) {
            return dep;
          }

          final packages = await cache.getVersions(dep.toRef());
          packages.sort((a, b) => a.version.compareTo(b.version));

          for (final package in packages) {
            final pubspec = await cache.describe(package);
            if (pubspec.languageVersion.supportsNullSafety) {
              hasNullSafetyVersions.add(dep.name);
              return dep.toRef().withConstraint(
                    VersionRange(min: package.version, includeMin: true),
                  );
            }
          }

          hasNoNullSafetyVersions.add(dep.name);
          // This value is never used. We will throw an exception because
          //`hasNonNullSafetyVersions` is not empty.
          return dep.toRef().withConstraint(VersionConstraint.empty);
        }));

    final deps = removeUpperConstraints(original.dependencies.values);
    final devDeps = removeUpperConstraints(original.devDependencies.values);
    await Future.wait([deps, devDeps]);

    if (hasNoNullSafetyVersions.isNotEmpty) {
      throw ApplicationException('''
null-safety compatible versions do not exist for:
 - ${hasNoNullSafetyVersions.join('\n - ')}

You can choose to upgrade only some dependencies to null-safety using:
  $topLevelProgram pub upgrade --nullsafety ${hasNullSafetyVersions.join(' ')}

Warning: Using null-safety features before upgrading all dependencies is
discouraged. For more details see: ${NullSafetyAnalysis.guideUrl}
''');
    }

    return Pubspec(
      original.name,
      version: original.version,
      sdkConstraints: original.sdkConstraints,
      dependencies: await deps,
      devDependencies: await devDeps,
      dependencyOverrides: original.dependencyOverrides.values,
    );
  }
}
