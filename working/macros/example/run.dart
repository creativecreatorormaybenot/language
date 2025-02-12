// Copyright (c) 2022, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Run this script to print out the generated augmentation library for an
// example class.
//
// This is primarily for illustration purposes, so we can get an idea of how
// things would work on a real-ish example.
library language.working.macros.example.run;

import 'dart:io';

import 'package:dart_style/dart_style.dart';

// There is no public API exposed yet, the in progress api lives here.
import 'package:_fe_analyzer_shared/src/macros/api.dart';

// Private impls used actually execute the macro
import 'package:_fe_analyzer_shared/src/macros/bootstrap.dart';
import 'package:_fe_analyzer_shared/src/macros/executor.dart';
import 'package:_fe_analyzer_shared/src/macros/executor/introspection_impls.dart';
import 'package:_fe_analyzer_shared/src/macros/executor/remote_instance.dart';
import 'package:_fe_analyzer_shared/src/macros/executor/serialization.dart';
import 'package:_fe_analyzer_shared/src/macros/executor/process_executor.dart'
    as processExecutor;

final _watch = Stopwatch()..start();
void _log(String message) {
  print('${_watch.elapsed}: $message');
}

const clientSerializationMode = SerializationMode.byteDataClient;
const serverSerializationMode = SerializationMode.byteDataServer;

// Run this script to print out the generated augmentation library for an example class.
void main() async {
  _log('Preparing to run macros.');
  // You must run from the `macros` directory, paths are relative to that.
  var thisFile = File('example/data_class.dart');
  if (!thisFile.existsSync()) {
    print('This script must be ran from the `macros` directory.');
    exit(1);
  }
  var executor = await processExecutor.start(serverSerializationMode);
  var tmpDir = Directory.systemTemp.createTempSync('data_class_macro_example');
  try {
    var macroUri = thisFile.absolute.uri;
    var macroName = 'DataClass';

    var bootstrapContent = bootstrapMacroIsolate({
      macroUri.toString(): {
        macroName: [''],
      }
    }, clientSerializationMode);

    var bootstrapFile = File(tmpDir.uri.resolve('main.dart').toFilePath())
      ..writeAsStringSync(bootstrapContent);
    var kernelOutputFile =
        File(tmpDir.uri.resolve('main.dart.dill').toFilePath());
    _log('Compiling DataClass macro');
    var buildSnapshotResult = await Process.run('dart', [
      'compile',
      'exe',
      '--packages=.dart_tool/package_config.json',
      bootstrapFile.uri.toFilePath(),
      '-o',
      kernelOutputFile.uri.toFilePath(),
    ]);

    if (buildSnapshotResult.exitCode != 0) {
      print('Failed to build macro boostrap isolate:\n'
          'stdout: ${buildSnapshotResult.stdout}\n'
          'stderr: ${buildSnapshotResult.stderr}');
      exit(1);
    }

    _log('Loading DataClass macro');
    var clazzId = await executor.loadMacro(macroUri, macroName,
        precompiledKernelUri: kernelOutputFile.uri);
    _log('Instantiating macro');
    var instanceId =
        await executor.instantiateMacro(clazzId, '', Arguments([], {}));

    _log('Running DataClass macro 100 times...');
    var results = <MacroExecutionResult>[];
    var macroExecutionStart = _watch.elapsed;
    late Duration firstRunEnd;
    late Duration first11RunsEnd;
    for (var i = 1; i <= 111; i++) {
      var _shouldLog = i == 1 || i == 10 || i == 100;
      if (_shouldLog) _log('Running DataClass macro for the ${i}th time');
      if (instanceId.shouldExecute(DeclarationKind.clazz, Phase.types)) {
        if (_shouldLog) _log('Running types phase');
        var result = await executor.executeTypesPhase(instanceId, myClass);
        if (i == 1) results.add(result);
      }
      if (instanceId.shouldExecute(DeclarationKind.clazz, Phase.declarations)) {
        if (_shouldLog) _log('Running declarations phase');
        var result = await executor.executeDeclarationsPhase(
            instanceId, myClass, FakeTypeResolver(), FakeClassIntrospector());
        if (i == 1) results.add(result);
      }
      if (instanceId.shouldExecute(DeclarationKind.clazz, Phase.definitions)) {
        if (_shouldLog) _log('Running definitions phase');
        var result = await executor.executeDefinitionsPhase(
            instanceId,
            myClass,
            FakeTypeResolver(),
            FakeClassIntrospector(),
            FakeTypeDeclarationResolver());
        if (i == 1) results.add(result);
      }
      if (_shouldLog) _log('Done running DataClass macro for the ${i}th time.');

      if (i == 1) {
        firstRunEnd = _watch.elapsed;
      } else if (i == 11) {
        first11RunsEnd = _watch.elapsed;
      }
    }
    var first111RunsEnd = _watch.elapsed;

    _log('Building augmentation library');
    var library = executor.buildAugmentationLibrary(results, (identifier) {
      if (identifier == boolIdentifier ||
          identifier == objectIdentifier ||
          identifier == stringIdentifier ||
          identifier == intIdentifier) {
        return ResolvedIdentifier(
            kind: IdentifierKind.topLevelMember,
            name: identifier.name,
            staticScope: null,
            uri: null);
      } else {
        return ResolvedIdentifier(
            kind: identifier.name == 'MyClass'
                ? IdentifierKind.topLevelMember
                : IdentifierKind.instanceMember,
            name: identifier.name,
            staticScope: null,
            uri: Platform.script.resolve('data_class.dart'));
      }
    });
    executor.close();
    _log('Formatting augmentation library');
    var formatted = DartFormatter()
        .format(library
            // comment out the `augment` keywords temporarily
            .replaceAll('augment', '/*augment*/'))
        .replaceAll('/*augment*/', 'augment');

    _log('Macro augmentation library:\n\n$formatted');
    _log('Time for the first run: ${macroExecutionStart - firstRunEnd}');
    _log('Average time for the next 10 runs: '
        '${(first11RunsEnd - firstRunEnd).dividedBy(10)}');
    _log('Average time for the next 100 runs: '
        '${(first111RunsEnd - first11RunsEnd).dividedBy(100)}');
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

final boolIdentifier =
    IdentifierImpl(id: RemoteInstance.uniqueId, name: 'bool');
final intIdentifier = IdentifierImpl(id: RemoteInstance.uniqueId, name: 'int');
final objectIdentifier =
    IdentifierImpl(id: RemoteInstance.uniqueId, name: 'Object');
final stringIdentifier =
    IdentifierImpl(id: RemoteInstance.uniqueId, name: 'String');

final boolType = NamedTypeAnnotationImpl(
    id: RemoteInstance.uniqueId,
    identifier: boolIdentifier,
    isNullable: false,
    typeArguments: const []);
final intType = NamedTypeAnnotationImpl(
    id: RemoteInstance.uniqueId,
    identifier: intIdentifier,
    isNullable: false,
    typeArguments: const []);
final stringType = NamedTypeAnnotationImpl(
    id: RemoteInstance.uniqueId,
    identifier: stringIdentifier,
    isNullable: false,
    typeArguments: const []);

final objectClass = ClassDeclarationImpl(
    id: RemoteInstance.uniqueId,
    identifier: objectIdentifier,
    interfaces: [],
    isAbstract: false,
    isExternal: false,
    mixins: [],
    superclass: null,
    typeParameters: []);

final myClassIdentifier =
    IdentifierImpl(id: RemoteInstance.uniqueId, name: 'MyClass');
final myClass = ClassDeclarationImpl(
    id: RemoteInstance.uniqueId,
    identifier: myClassIdentifier,
    interfaces: [],
    isAbstract: false,
    isExternal: false,
    mixins: [],
    superclass: NamedTypeAnnotationImpl(
      id: RemoteInstance.uniqueId,
      isNullable: false,
      identifier: objectIdentifier,
      typeArguments: [],
    ),
    typeParameters: []);

final myClassFields = [
  FieldDeclarationImpl(
      definingClass: myClassIdentifier,
      id: RemoteInstance.uniqueId,
      identifier: IdentifierImpl(id: RemoteInstance.uniqueId, name: 'myString'),
      isExternal: false,
      isFinal: true,
      isLate: false,
      isStatic: false,
      type: stringType),
  FieldDeclarationImpl(
      definingClass: myClassIdentifier,
      id: RemoteInstance.uniqueId,
      identifier: IdentifierImpl(id: RemoteInstance.uniqueId, name: 'myBool'),
      isExternal: false,
      isFinal: true,
      isLate: false,
      isStatic: false,
      type: boolType),
];

final myClassMethods = [
  MethodDeclarationImpl(
    definingClass: myClassIdentifier,
    id: RemoteInstance.uniqueId,
    identifier: IdentifierImpl(id: RemoteInstance.uniqueId, name: '=='),
    isAbstract: false,
    isExternal: false,
    isGetter: false,
    isOperator: true,
    isSetter: false,
    isStatic: false,
    namedParameters: [],
    positionalParameters: [
      ParameterDeclarationImpl(
        id: RemoteInstance.uniqueId,
        identifier: IdentifierImpl(id: RemoteInstance.uniqueId, name: 'other'),
        isNamed: false,
        isRequired: true,
        type: NamedTypeAnnotationImpl(
            id: RemoteInstance.uniqueId,
            identifier: objectIdentifier,
            isNullable: false,
            typeArguments: const []),
      )
    ],
    returnType: boolType,
    typeParameters: [],
  ),
  MethodDeclarationImpl(
    definingClass: myClassIdentifier,
    id: RemoteInstance.uniqueId,
    identifier: IdentifierImpl(id: RemoteInstance.uniqueId, name: 'hashCode'),
    isAbstract: false,
    isExternal: false,
    isOperator: false,
    isGetter: true,
    isSetter: false,
    isStatic: false,
    namedParameters: [],
    positionalParameters: [],
    returnType: intType,
    typeParameters: [],
  ),
  MethodDeclarationImpl(
    definingClass: myClassIdentifier,
    id: RemoteInstance.uniqueId,
    identifier: IdentifierImpl(id: RemoteInstance.uniqueId, name: 'toString'),
    isAbstract: false,
    isExternal: false,
    isGetter: false,
    isOperator: false,
    isSetter: false,
    isStatic: false,
    namedParameters: [],
    positionalParameters: [],
    returnType: stringType,
    typeParameters: [],
  ),
];

abstract class Fake {
  @override
  void noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class FakeClassIntrospector extends Fake implements ClassIntrospector {
  @override
  Future<List<ConstructorDeclaration>> constructorsOf(
          covariant ClassDeclaration clazz) async =>
      [];

  @override
  Future<List<FieldDeclaration>> fieldsOf(
          covariant ClassDeclaration clazz) async =>
      myClassFields;

  @override
  Future<List<MethodDeclaration>> methodsOf(
          covariant ClassDeclaration clazz) async =>
      myClassMethods;

  @override
  Future<ClassDeclaration?> superclassOf(
          covariant ClassDeclaration clazz) async =>
      clazz == myClass ? objectClass : null;
}

class FakeTypeDeclarationResolver extends Fake
    implements TypeDeclarationResolver {}

class FakeTypeResolver extends Fake implements TypeResolver {}

extension _ on Duration {
  Duration dividedBy(int amount) =>
      Duration(microseconds: (this.inMicroseconds / amount).round());
}
