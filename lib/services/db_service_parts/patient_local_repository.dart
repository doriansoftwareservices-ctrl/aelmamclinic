part of db_service;

class PatientLocalRepository {
  PatientLocalRepository.test(this._dbService);

  PatientLocalRepository(this._dbService);

  final DBService _dbService;

  Future<int> insertPatient(Patient patient) async {
    final db = await _dbService.database;
    final data = patient.toMap();
    if ((patient.doctorId ?? 0) != 0) {
      data['doctorReviewPending'] = 1;
      data['doctorReviewedAt'] = null;
    }
    final id = await db.insert('patients', data);
    await _dbService._markChanged('patients');
    return id;
  }

  Future<List<Patient>> getAllPatients({int? doctorId}) async {
    final db = await _dbService.database;
    final args = <Object?>[];
    final where = StringBuffer('WHERE ifnull(p.isDeleted,0)=0');
    if (doctorId != null) {
      where.write(' AND p.doctorId = ?');
      args.add(doctorId);
    }
    final sql = '''
      SELECT
        p.*,
        d.name AS doctorName,
        d.specialization AS doctorSpecialization
      FROM patients p
      LEFT JOIN doctors d ON d.id = p.doctorId
      ${where.toString()}
      ORDER BY p.registerDate DESC
    ''';
    final rows = await db.rawQuery(sql, args);
    return rows
        .map((row) => Patient.fromMap(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<Patient?> getPatientById(int id) async {
    final db = await _dbService.database;
    final rows = await db.query(
      'patients',
      where: 'id = ? AND ifnull(isDeleted,0)=0',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Patient.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<int> markPatientReviewed(int id) async {
    final db = await _dbService.database;
    final now = DateTime.now().toIso8601String();
    final count = await db.update(
      'patients',
      {
        'doctorReviewPending': 0,
        'doctorReviewedAt': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    await _dbService._markChanged('patients');
    return count;
  }

  Future<int> updatePatient(
    Patient patient,
    List<PatientService> newServices,
  ) async {
    final db = await _dbService.database;
    final data = patient.toMap();
    Map<String, Object?>? existing;
    if (patient.id != null) {
      final rows = await db.query(
        'patients',
        columns: const ['doctorId', 'doctorReviewPending'],
        where: 'id = ?',
        whereArgs: [patient.id],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        existing = Map<String, Object?>.from(rows.first);
      }
    }

    final int currentDoctor = (patient.doctorId ?? 0);
    final int previousDoctor = (() {
      final raw = existing?['doctorId'];
      if (raw is num) return raw.toInt();
      return int.tryParse('${raw ?? 0}') ?? 0;
    })();

    if (currentDoctor == 0) {
      data['doctorReviewPending'] = 0;
      data['doctorReviewedAt'] = null;
    } else if (currentDoctor != previousDoctor) {
      data['doctorReviewPending'] = 1;
      data['doctorReviewedAt'] = null;
    }

    final count = await db.update(
      'patients',
      data,
      where: 'id = ?',
      whereArgs: [patient.id],
    );

    if (patient.id != null) {
      await _dbService.deletePatientServices(patient.id!);
      for (final service in newServices) {
        final toInsert = (service.patientId == patient.id)
            ? service
            : service.copyWith(patientId: patient.id);
        await _dbService.insertPatientService(toInsert);
      }
    }

    await _dbService._markChanged('patients');
    return count;
  }

  Future<int> deletePatient(int id, {bool restoreStock = true}) async {
    final db = await _dbService.database;
    final now = DateTime.now().toIso8601String();
    var touchedItems = false;
    var touchedConsumptions = false;
    var touchedServices = false;

    final count = await db.transaction((txn) async {
      final rows = await txn.update(
        'patients',
        {'isDeleted': 1, 'deletedAt': now},
        where: 'id = ?',
        whereArgs: [id],
      );

      await txn.update(
        PatientService.table,
        {'isDeleted': 1, 'deletedAt': now},
        where: 'patientId = ?',
        whereArgs: [id],
      );
      touchedServices = true;

      // استهلاكات المريض
      final cons = await txn.query(
        Consumption.table,
        columns: const ['id', 'itemId', 'quantity'],
        where: 'patientId = ? AND ifnull(isDeleted,0)=0',
        whereArgs: [id.toString()],
      );

      if (cons.isNotEmpty) {
        await txn.update(
          Consumption.table,
          {'isDeleted': 1, 'deletedAt': now},
          where: 'patientId = ?',
          whereArgs: [id.toString()],
        );
        touchedConsumptions = true;

        if (restoreStock) {
          for (final c in cons) {
            final itemIdRaw = c['itemId']?.toString();
            final itemId = int.tryParse(itemIdRaw ?? '');
            final qty = (c['quantity'] is num)
                ? (c['quantity'] as num).toInt()
                : int.tryParse('${c['quantity'] ?? 0}') ?? 0;
            if (itemId != null && itemId > 0 && qty > 0) {
              await txn.rawUpdate(
                'UPDATE items SET stock = stock + ? WHERE id = ?',
                [qty, itemId],
              );
              touchedItems = true;
            }
          }
        }
      }

      return rows;
    });

    await _dbService._markChanged('patients');
    if (touchedServices) await _dbService._markChanged(PatientService.table);
    if (touchedConsumptions) await _dbService._markChanged(Consumption.table);
    if (touchedItems) await _dbService._markChanged(Item.table);
    return count;
  }
}
