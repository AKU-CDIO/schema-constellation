# -*- coding: utf-8 -*-
"""Generate the 32 dedicated FCAP1A topic procedures that complete the portfolio."""
from __future__ import annotations

import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "dev", "fcap1a_utf8")
LINK = "[NBIDRSRV2].[AKULiveATdb].[dbo]"

COMMON_EVENT_COLUMNS = [
    ("EventKey", "NVARCHAR(250)", False), ("SourceID", "VARCHAR(3)", True),
    ("PatientID", "NVARCHAR(50)", False), ("VisitID", "NVARCHAR(50)", True),
    ("SourceRecordID", "NVARCHAR(100)", True), ("TopicCode", "VARCHAR(30)", False),
    ("SourceKind", "VARCHAR(30)", False), ("ClinicalName", "NVARCHAR(300)", True),
    ("EventDateTime", "DATETIME2(0)", True), ("OrderDateTime", "DATETIME2(0)", True),
    ("ResultDateTime", "DATETIME2(0)", True), ("Status", "NVARCHAR(100)", True),
    ("Priority", "NVARCHAR(60)", True), ("ProviderID", "NVARCHAR(100)", True),
    ("FacilityID", "NVARCHAR(60)", True), ("LocationID", "NVARCHAR(60)", True),
    ("OrderNumber", "NVARCHAR(100)", True), ("ResultIdentifier", "NVARCHAR(200)", True),
    ("InterpretationType", "NVARCHAR(100)", True), ("ResultReference", "NVARCHAR(1000)", True),
    ("AssetAvailable", "BIT", False), ("ExternalAssetRequired", "BIT", False),
    ("EvidenceTier", "VARCHAR(40)", False), ("CoverageNote", "NVARCHAR(500)", True),
    ("SourceTable", "SYSNAME", False), ("RowUpdateDateTime", "DATETIME2(0)", True),
    ("ExtractedOn", "DATETIME2(0)", False),
]


def q(name):
    return "[" + name.replace("]", "]]" ) + "]"


def create_columns(columns):
    return ",\n            ".join(f"{q(name)} {sql_type} {'NULL' if nullable else 'NOT NULL'}" for name, sql_type, nullable in columns)


def column_list(columns):
    return ", ".join(q(name) for name, _, _ in columns)


def render(spec):
    proc = spec["procedure"]
    output = spec["output"]
    columns = spec["columns"]
    key = spec.get("key", columns[0][0])
    time_col = spec.get("time", next((name for name, _, _ in columns if name.endswith("DateTime")), None))
    patient_col = spec.get("patient", "PatientID")
    ix_stem = re.sub(r"[^A-Za-z0-9]", "", output.replace("tbl_FCAP1A_", ""))[:42]
    secondary = ""
    if patient_col and any(c[0] == patient_col for c in columns):
        keys = q(patient_col) + (", " + q(time_col) if time_col and any(c[0] == time_col for c in columns) else "")
        secondary = f"""
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.{output}') AND name = N'IX_{ix_stem}_PatientTime')
            CREATE INDEX [IX_{ix_stem}_PatientTime] ON dbo.{q(output)} ({keys});"""
    sql = f"""USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.{proc}
    Purpose   : {spec['purpose']}
    Grain     : {spec['grain']}
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.{q(proc)}
    @WindowStart DATE = '2022-11-05',
    @WindowEnd DATE = '2026-06-14',
    @MinimumPublishRows BIGINT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @WindowStart IS NULL OR @WindowEnd IS NULL OR @WindowStart > @WindowEnd
        THROW 51000, 'A valid inclusive extraction window is required.', 1;
    IF @MinimumPublishRows < 1
        THROW 51000, 'MinimumPublishRows must be at least one.', 1;

    DECLARE @RunStart DATETIME2(0) = SYSDATETIME(), @RunEnd DATETIME2(0),
            @RecordCount BIGINT = 0, @TotalEligible BIGINT = 0;

    IF OBJECT_ID(N'dbo.FCAP1A_Cohort_Log', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID INT IDENTITY(1,1) PRIMARY KEY, RunStart DATETIME NOT NULL, RunEnd DATETIME NULL,
            DurationSeconds INT NULL, RunStatus VARCHAR(20) NOT NULL, DataTopic NVARCHAR(100) NOT NULL,
            WindowStart DATE NULL, WindowEnd DATE NULL, TotalEligible INT NULL, RecordCount INT NULL,
            ProcessedBy NVARCHAR(100) DEFAULT SYSTEM_USER, ErrorMessage NVARCHAR(4000) NULL,
            Remarks NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID(N'dbo.{output}', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.{q(output)} (
            {create_columns(columns)}
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.{output}') AND name = N'UX_{ix_stem}_Key')
        CREATE UNIQUE INDEX [UX_{ix_stem}_Key] ON dbo.{q(output)} ({q(key)});{secondary}

    BEGIN TRY
        CREATE TABLE #Build (
            {create_columns(columns)}
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

{spec['body']}

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.{q(output)};
            INSERT INTO dbo.{q(output)} ({column_list(columns)})
            SELECT {column_list(columns)} FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'{spec['topic']}',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             N'Author: test; staged and minimum-row-gated publication.');
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, ErrorMessage, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'{spec['topic']}',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
"""
    return sql


def generic_body(topic_id, terms, external, coverage):
    predicates = " OR\n                ".join(
        "UPPER(CONCAT_WS(' ', d.Mnemonic, d.Name, d.CategoryName, d.Type, o.OrderType, o2.Alias)) LIKE '%" + term.upper().replace("'", "''") + "%'"
        for term in terms
    )
    report_predicates = " OR\n                ".join(
        "UPPER(CONCAT_WS(' ', i.Vendor, i.ImageIdentifier, i.ImageStatus, i.ImageInterpretationType, i.ImageUrl)) LIKE '%" + term.upper().replace("'", "''") + "%'"
        for term in terms
    )
    cols = column_list(COMMON_EVENT_COLUMNS)
    return f"""        ;WITH Evidence AS (
            SELECT
                CONVERT(NVARCHAR(250), CONCAT('ORDER|', o.SourceID, '|', o.OmOrdID)) AS EventKey,
                o.SourceID, CONVERT(NVARCHAR(50), o.PatientID) AS PatientID,
                CONVERT(NVARCHAR(50), o.VisitID) AS VisitID, CONVERT(NVARCHAR(100), o.OmOrdID) AS SourceRecordID,
                CONVERT(VARCHAR(30), '{topic_id}') AS TopicCode, CONVERT(VARCHAR(30), 'order') AS SourceKind,
                CONVERT(NVARCHAR(300), COALESCE(d.Name, d.Mnemonic, o2.Alias, o.OrderType)) AS ClinicalName,
                CONVERT(DATETIME2(0), COALESCE(o3.LastEventDateTime, o3.StartDateTime, o.OrderDateTime)) AS EventDateTime,
                CONVERT(DATETIME2(0), o.OrderDateTime) AS OrderDateTime, CONVERT(DATETIME2(0), o3.LastEventDateTime) AS ResultDateTime,
                CONVERT(NVARCHAR(100), o3.Status) AS Status, CONVERT(NVARCHAR(60), o2.Priority) AS Priority,
                CONVERT(NVARCHAR(100), COALESCE(o2.OrderProvider, o3.RequestProvider, o.OrderUser_UnvUserID)) AS ProviderID,
                CONVERT(NVARCHAR(60), o.Facility_MisFacID) AS FacilityID,
                CONVERT(NVARCHAR(60), COALESCE(o3.OrderLocation_MisLocID, o2.RequisitionLocation_MisLocID)) AS LocationID,
                CONVERT(NVARCHAR(100), o.OrderNumber) AS OrderNumber, CONVERT(NVARCHAR(200), d.Mnemonic) AS ResultIdentifier,
                CONVERT(NVARCHAR(100), NULL) AS InterpretationType, CONVERT(NVARCHAR(1000), NULL) AS ResultReference,
                CONVERT(BIT, 0) AS AssetAvailable, CONVERT(BIT, {1 if external else 0}) AS ExternalAssetRequired,
                CONVERT(VARCHAR(40), 'relational-order') AS EvidenceTier,
                CONVERT(NVARCHAR(500), N'{coverage.replace("'", "''")}') AS CoverageNote,
                CONVERT(SYSNAME, 'OmOrd_Main') AS SourceTable,
                CONVERT(DATETIME2(0), COALESCE(o3.RowUpdateDateTime, o2.RowUpdateDateTime, o.RowUpdateDateTime)) AS RowUpdateDateTime,
                CONVERT(DATETIME2(0), SYSDATETIME()) AS ExtractedOn
            FROM {LINK}.OmOrd_Main o
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = o.PatientID
            LEFT JOIN {LINK}.OmOrd_Main2 o2 ON o2.SourceID = o.SourceID AND o2.OmOrdID = o.OmOrdID
            LEFT JOIN {LINK}.OmOrd_Main3 o3 ON o3.SourceID = o.SourceID AND o3.OmOrdID = o.OmOrdID
            LEFT JOIN {LINK}.OmOrdDict_Main d ON d.SourceID = o.SourceID AND d.OmOrdDictID = o2.Procedure_OmOrdDictID
            WHERE o.OrderDateTime >= @WindowStart AND o.OrderDateTime < DATEADD(DAY, 1, @WindowEnd)
              AND ({predicates})

            UNION ALL

            SELECT
                CONVERT(NVARCHAR(250), CONCAT('REPORT|', i.SourceID, '|', i.VisitID, '|', i.DataUrnID, '|', i.ImageKeyID)),
                i.SourceID, CONVERT(NVARCHAR(50), r.PatientID), CONVERT(NVARCHAR(50), i.VisitID),
                CONVERT(NVARCHAR(100), CONCAT_WS('|', i.DataUrnID, i.ImageKeyID)), CONVERT(VARCHAR(30), '{topic_id}'),
                CONVERT(VARCHAR(30), 'report'), CONVERT(NVARCHAR(300), COALESCE(i.ImageInterpretationType, i.Vendor, i.ImageIdentifier)),
                CONVERT(DATETIME2(0), COALESCE(i.ImageDate, i.RowUpdateDateTime)), NULL,
                CONVERT(DATETIME2(0), COALESCE(i.ImageDate, i.RowUpdateDateTime)), CONVERT(NVARCHAR(100), i.ImageStatus), NULL, NULL,
                NULL, NULL, NULL, CONVERT(NVARCHAR(200), i.ImageIdentifier), CONVERT(NVARCHAR(100), i.ImageInterpretationType),
                CONVERT(NVARCHAR(1000), i.ImageUrl), CONVERT(BIT, IIF(NULLIF(LTRIM(RTRIM(i.ImageUrl)), '') IS NULL, 0, 1)),
                CONVERT(BIT, {1 if external else 0}), CONVERT(VARCHAR(40), 'relational-report'),
                CONVERT(NVARCHAR(500), N'{coverage.replace("'", "''")}'), CONVERT(SYSNAME, 'EmrAcctRep_Images'),
                CONVERT(DATETIME2(0), i.RowUpdateDateTime), CONVERT(DATETIME2(0), SYSDATETIME())
            FROM {LINK}.EmrAcctRep_Images i
            INNER JOIN {LINK}.RegAcct_Main r ON r.SourceID = i.SourceID AND r.VisitID = i.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            WHERE COALESCE(i.ImageDate, i.RowUpdateDateTime) >= @WindowStart
              AND COALESCE(i.ImageDate, i.RowUpdateDateTime) < DATEADD(DAY, 1, @WindowEnd)
              AND ({report_predicates})
        ), Ranked AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY EventKey ORDER BY RowUpdateDateTime DESC, SourceKind) AS rn
            FROM Evidence
        )
        INSERT #Build ({cols})
        SELECT {cols} FROM Ranked WHERE rn = 1;"""


def generic_spec(topic_id, label, suffix, terms, external, coverage, grain):
    return {
        "procedure": "usp_Build_FCAP1A_" + suffix, "output": "tbl_FCAP1A_" + suffix,
        "topic": label, "purpose": "Builds cohort-scoped " + label + " evidence from audited orders and report metadata.",
        "grain": grain, "columns": COMMON_EVENT_COLUMNS, "key": "EventKey", "time": "EventDateTime",
        "body": generic_body(topic_id, terms, external, coverage),
    }


ORDER_COLUMNS = [
    ("OrderKey", "NVARCHAR(160)", False), ("SourceID", "VARCHAR(3)", True),
    ("PatientID", "NVARCHAR(50)", False), ("VisitID", "NVARCHAR(50)", True),
    ("OrderID", "NVARCHAR(80)", False), ("OrderNumber", "NVARCHAR(100)", True),
    ("OrderDateTime", "DATETIME2(0)", True), ("StartDateTime", "DATETIME2(0)", True),
    ("LastEventDateTime", "DATETIME2(0)", True), ("Status", "NVARCHAR(100)", True),
    ("OrderType", "NVARCHAR(100)", True), ("ProcedureID", "NVARCHAR(80)", True),
    ("Mnemonic", "NVARCHAR(100)", True), ("OrderName", "NVARCHAR(300)", True),
    ("CategoryID", "NVARCHAR(80)", True), ("CategoryName", "NVARCHAR(200)", True),
    ("Priority", "NVARCHAR(60)", True), ("Quantity", "DECIMAL(18,4)", True),
    ("OrderingProviderID", "NVARCHAR(100)", True), ("RequestingProviderID", "NVARCHAR(100)", True),
    ("FacilityID", "NVARCHAR(60)", True), ("LocationID", "NVARCHAR(60)", True),
    ("OrderOrigin", "NVARCHAR(100)", True), ("MedicationIndicator", "BIT", False),
    ("SourceTable", "SYSNAME", False), ("RowUpdateDateTime", "DATETIME2(0)", True),
    ("ExtractedOn", "DATETIME2(0)", False),
]


def order_spec(topic, suffix, medication):
    cols = column_list(ORDER_COLUMNS)
    indicator = "(NULLIF(o.AomMedicationType, '') IS NOT NULL OR d.AmbulatoryMedication IN ('Y','YES') OR d.Type LIKE '%MED%')"
    predicate = indicator if medication else "NOT " + indicator
    return {
        "procedure": "usp_Build_FCAP1A_" + suffix, "output": "tbl_FCAP1A_" + suffix,
        "topic": topic, "purpose": "Builds a dedicated cohort-scoped order contract with dictionary and lifecycle context.",
        "grain": "one row per order", "columns": ORDER_COLUMNS, "key": "OrderKey", "time": "OrderDateTime",
        "body": f"""        ;WITH Ranked AS (
            SELECT o.*, o2.Procedure_OmOrdDictID, o2.Priority, o2.Quantity, o2.OrderProvider,
                   o2.RequisitionLocation_MisLocID, o3.StartDateTime, o3.LastEventDateTime,
                   o3.Status, o3.RequestProvider, o3.OrderLocation_MisLocID,
                   d.Mnemonic, d.Name AS OrderName, d.CategoryName, d.Type AS DictionaryType,
                   d.AmbulatoryMedication, CONVERT(BIT, IIF({indicator}, 1, 0)) AS MedicationIndicator,
                   ROW_NUMBER() OVER (PARTITION BY o.SourceID, o.OmOrdID
                                      ORDER BY COALESCE(o3.RowUpdateDateTime, o2.RowUpdateDateTime, o.RowUpdateDateTime) DESC) AS rn
            FROM {LINK}.OmOrd_Main o
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = o.PatientID
            LEFT JOIN {LINK}.OmOrd_Main2 o2 ON o2.SourceID = o.SourceID AND o2.OmOrdID = o.OmOrdID
            LEFT JOIN {LINK}.OmOrd_Main3 o3 ON o3.SourceID = o.SourceID AND o3.OmOrdID = o.OmOrdID
            LEFT JOIN {LINK}.OmOrdDict_Main d ON d.SourceID = o.SourceID AND d.OmOrdDictID = o2.Procedure_OmOrdDictID
            WHERE o.OrderDateTime >= @WindowStart AND o.OrderDateTime < DATEADD(DAY, 1, @WindowEnd)
              AND {predicate}
        )
        INSERT #Build ({cols})
        SELECT CONVERT(NVARCHAR(160), CONCAT(SourceID, '|', OmOrdID)), SourceID,
               CONVERT(NVARCHAR(50), PatientID), CONVERT(NVARCHAR(50), VisitID), CONVERT(NVARCHAR(80), OmOrdID),
               CONVERT(NVARCHAR(100), OrderNumber), CONVERT(DATETIME2(0), OrderDateTime), CONVERT(DATETIME2(0), StartDateTime),
               CONVERT(DATETIME2(0), LastEventDateTime), CONVERT(NVARCHAR(100), Status), CONVERT(NVARCHAR(100), OrderType),
               CONVERT(NVARCHAR(80), Procedure_OmOrdDictID), CONVERT(NVARCHAR(100), Mnemonic), CONVERT(NVARCHAR(300), OrderName),
               CONVERT(NVARCHAR(80), Category_OmCatID), CONVERT(NVARCHAR(200), CategoryName), CONVERT(NVARCHAR(60), Priority),
               TRY_CONVERT(DECIMAL(18,4), Quantity), CONVERT(NVARCHAR(100), OrderProvider), CONVERT(NVARCHAR(100), RequestProvider),
               CONVERT(NVARCHAR(60), Facility_MisFacID), CONVERT(NVARCHAR(60), COALESCE(OrderLocation_MisLocID, RequisitionLocation_MisLocID)),
               CONVERT(NVARCHAR(100), OrderOrigin), MedicationIndicator,
               CONVERT(SYSNAME, 'OmOrd_Main'), CONVERT(DATETIME2(0), RowUpdateDateTime), CONVERT(DATETIME2(0), SYSDATETIME())
        FROM Ranked WHERE rn = 1;""",
    }


def appointments_spec():
    columns = [
        ("AppointmentKey", "NVARCHAR(160)", False), ("SourceID", "VARCHAR(3)", True),
        ("PatientID", "NVARCHAR(50)", False), ("VisitID", "NVARCHAR(50)", True),
        ("AppointmentID", "NVARCHAR(80)", False), ("AppointmentDateTime", "DATETIME2(0)", True),
        ("ArrivalDateTime", "DATETIME2(0)", True), ("ReservationDateTime", "DATETIME2(0)", True),
        ("DurationMinutes", "INT", True), ("OriginalDurationMinutes", "INT", True),
        ("StatusID", "NVARCHAR(80)", True), ("AppointmentType", "NVARCHAR(100)", True),
        ("ProcedureID", "NVARCHAR(80)", True), ("Reason", "NVARCHAR(1000)", True),
        ("ProviderID", "NVARCHAR(100)", True), ("FacilityID", "NVARCHAR(60)", True),
        ("LocationID", "NVARCHAR(60)", True), ("ConfirmationNumber", "NVARCHAR(100)", True),
        ("ReservationComment", "NVARCHAR(2000)", True), ("AppointmentComment", "NVARCHAR(MAX)", True),
        ("ResourceCount", "INT", False), ("ParticipantCount", "INT", False),
        ("LastAuditDateTime", "DATETIME2(0)", True), ("LastAuditType", "NVARCHAR(100)", True),
        ("ExternalSource", "NVARCHAR(100)", True), ("VideoVisitIdentifier", "NVARCHAR(200)", True),
        ("RowUpdateDateTime", "DATETIME2(0)", True), ("ExtractedOn", "DATETIME2(0)", False),
    ]
    cols = column_list(columns)
    return {
        "procedure": "usp_Build_FCAP1A_Appointments", "output": "tbl_FCAP1A_Appointments",
        "topic": "Appointments", "purpose": "Builds appointment occurrences with status, arrival, comments, resources, participants, and audit history.",
        "grain": "one row per scheduled appointment occurrence", "columns": columns, "key": "AppointmentKey", "time": "AppointmentDateTime",
        "body": f"""        INSERT #Build ({cols})
        SELECT CONVERT(NVARCHAR(160), CONCAT(a.SourceID, '|', a.CwsApptID)), a.SourceID,
               CONVERT(NVARCHAR(50), a.PatientID), CONVERT(NVARCHAR(50), a.VisitID), CONVERT(NVARCHAR(80), a.CwsApptID),
               CONVERT(DATETIME2(0), a.DateTime), CONVERT(DATETIME2(0), a.ArrivalDateTime), CONVERT(DATETIME2(0), a.ResvDateTime),
               TRY_CONVERT(INT, a.Duration), TRY_CONVERT(INT, a.OriginalDuration), CONVERT(NVARCHAR(80), a.Status_CwsApptStatusID),
               CONVERT(NVARCHAR(100), COALESCE(a.AmbulatoryType, a.Type, a.SpecialType)),
               CONVERT(NVARCHAR(80), a.Appointment_CwsApptProcID), CONVERT(NVARCHAR(1000), a.AppointmentReason),
               CONVERT(NVARCHAR(100), a.Provider), CONVERT(NVARCHAR(60), a.Facility_MisFacID),
               CONVERT(NVARCHAR(60), a.Location_MisLocID), CONVERT(NVARCHAR(100), a.ConfirmationNumber),
               CONVERT(NVARCHAR(2000), a.ReservationComment), CONVERT(NVARCHAR(MAX), NULL),
               CONVERT(INT, ISNULL(rc.ResourceCount, 0)), CONVERT(INT, 0),
               CONVERT(DATETIME2(0), au.AuditDateTime), CONVERT(NVARCHAR(100), au.AuditType),
               CONVERT(NVARCHAR(100), a.ExternalSource), CONVERT(NVARCHAR(200), a.VideoVisitIdentifierZold),
               CONVERT(DATETIME2(0), a.RowUpdateDateTime), CONVERT(DATETIME2(0), SYSDATETIME())
        FROM {LINK}.CwsAppt_Main a
        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = a.PatientID
        OUTER APPLY (SELECT COUNT_BIG(*) AS ResourceCount FROM {LINK}.CwsAppt_Resources x
                     WHERE x.SourceID = a.SourceID AND x.CwsApptID = a.CwsApptID) rc
        OUTER APPLY (SELECT TOP (1) x.AuditDateTime, x.AuditType FROM {LINK}.CwsAppt_AuditTrail x
                     WHERE x.SourceID = a.SourceID AND x.CwsApptID = a.CwsApptID ORDER BY x.AuditDateTime DESC, x.AuditUrnID DESC) au
        WHERE a.DateTime >= @WindowStart AND a.DateTime < DATEADD(DAY, 1, @WindowEnd);""",
    }


def infusion_spec():
    columns = [
        ("InfusionEventKey", "NVARCHAR(250)", False), ("SourceID", "VARCHAR(3)", True),
        ("PatientID", "NVARCHAR(50)", False), ("VisitID", "NVARCHAR(50)", False),
        ("PrescriptionID", "NVARCHAR(100)", True), ("BottleID", "NVARCHAR(100)", True),
        ("EventKind", "VARCHAR(40)", False), ("ScheduleDateTime", "DATETIME2(0)", True),
        ("AdministrationStartDateTime", "DATETIME2(0)", True), ("MedicationTradeName", "NVARCHAR(300)", True),
        ("MedicationGenericName", "NVARCHAR(300)", True), ("Administration", "NVARCHAR(200)", True),
        ("Dose", "DECIMAL(18,4)", True), ("DoseUnits", "NVARCHAR(60)", True),
        ("Rate", "DECIMAL(18,4)", True), ("RateUnits", "NVARCHAR(60)", True),
        ("Volume", "DECIMAL(18,4)", True), ("InfusionType", "NVARCHAR(100)", True),
        ("InfusionStatus", "NVARCHAR(100)", True), ("TotalIntake", "DECIMAL(18,4)", True),
        ("ElapsedTime", "DECIMAL(18,4)", True), ("TotalDose", "DECIMAL(18,4)", True),
        ("BolusDescription", "NVARCHAR(500)", True), ("DocumentedByUserID", "NVARCHAR(100)", True),
        ("SourceTable", "SYSNAME", False), ("RowUpdateDateTime", "DATETIME2(0)", True),
        ("ExtractedOn", "DATETIME2(0)", False),
    ]
    cols = column_list(columns)
    nulls = "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL"
    return {
        "procedure": "usp_Build_FCAP1A_Infusions", "output": "tbl_FCAP1A_Infusions",
        "topic": "Infusions", "purpose": "Builds infusion documentation, titration, and bag events from the MAR activity family.",
        "grain": "one row per documented infusion or titration event", "columns": columns, "key": "InfusionEventKey", "time": "AdministrationStartDateTime",
        "body": f"""        ;WITH InfusionEvents AS (
            SELECT CONVERT(NVARCHAR(250), CONCAT('DOC|', d.SourceID, '|', d.VisitID, '|', d.MarLastDocumentedPrescriptionID, '|', d.MarLastDocumentedBottleID, '|', d.MarLastDocumentedActivityUrn)) AS InfusionEventKey,
                   d.SourceID, r.PatientID, d.VisitID, d.MarLastDocumentedPrescriptionID AS PrescriptionID,
                   d.MarLastDocumentedBottleID AS BottleID, CONVERT(VARCHAR(40), 'last-documented') AS EventKind,
                   d.MarLastDocumentedScheduleDateTime AS ScheduleDateTime, d.MarLastDocumentedDateTime AS AdministrationStartDateTime,
                   COALESCE(m.MedicationTradeName, d.MarLastDocumentedPrescriptionTradeName) AS MedicationTradeName,
                   COALESCE(m.MedicationGenericName, d.MarLastDocumentedPrescriptionGenericName) AS MedicationGenericName,
                   d.MarLastDocumentedAdministration AS Administration, TRY_CONVERT(DECIMAL(18,4), d.MarLastDocumentedDose) AS Dose,
                   d.MarLastDocumentedUnits AS DoseUnits, TRY_CONVERT(DECIMAL(18,4), d.MarLastDocumentedInfusionRate) AS Rate,
                   d.MarLastDocumentedInfusionRateUnits AS RateUnits, TRY_CONVERT(DECIMAL(18,4), d.MarLastDocumentedInfusionVolume) AS Volume,
                   d.MarLastDocumentedInfusionType AS InfusionType, d.MarLastDocumentedInfusionStatus AS InfusionStatus,
                   TRY_CONVERT(DECIMAL(18,4), d.MarLastDocumentedInfusionTotalIntakePrescription) AS TotalIntake,
                   TRY_CONVERT(DECIMAL(18,4), d.MarLastDocumentedInfusionElapsedTime) AS ElapsedTime,
                   TRY_CONVERT(DECIMAL(18,4), d.MarLastDocumentedInfusionTotalDose) AS TotalDose,
                   d.MarLastDocumentedBolusString AS BolusDescription, d.MarLastDocumentedUser AS DocumentedByUserID,
                   CONVERT(SYSNAME, 'PcsMarAct_MarLastDocumented') AS SourceTable, d.RowUpdateDateTime
            FROM {LINK}.PcsMarAct_MarLastDocumented d
            INNER JOIN {LINK}.RegAcct_Main r ON r.SourceID = d.SourceID AND r.VisitID = d.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            LEFT JOIN {LINK}.PcsMarAct_MarMeds m ON m.SourceID = d.SourceID AND m.VisitID = d.VisitID
                AND m.MedicationPrescriptionNumberID = d.MarLastDocumentedPrescriptionID AND m.MarBottleNumberID = d.MarLastDocumentedBottleID
            LEFT JOIN {LINK}.PcsMarAct_MarRxs rx ON rx.SourceID=d.SourceID AND rx.VisitID=d.VisitID
                AND rx.MedicationPrescriptionNumberID=d.MarLastDocumentedPrescriptionID AND rx.MarBottleNumberID=d.MarLastDocumentedBottleID
            WHERE d.MarLastDocumentedDateTime >= @WindowStart AND d.MarLastDocumentedDateTime < DATEADD(DAY, 1, @WindowEnd)

            UNION ALL
            SELECT CONVERT(NVARCHAR(250), CONCAT('TITR|', t.SourceID, '|', t.VisitID, '|', t.MarLastTitrationPrescriptionID, '|', t.MarLastTitrationBottleID, '|', t.MarLastTitrationActivityUrn)),
                   t.SourceID, r.PatientID, t.VisitID, t.MarLastTitrationPrescriptionID, t.MarLastTitrationBottleID, CONVERT(VARCHAR(40), 'last-titration'),
                   t.MarLastTitrationScheduleDateTime, t.MarLastTitrationDateTime, m.MedicationTradeName, m.MedicationGenericName, NULL,
                   TRY_CONVERT(DECIMAL(18,4), t.MarLastTitrationDose), t.MarLastTitrationDoseUnits,
                   TRY_CONVERT(DECIMAL(18,4), t.MarLastTitrationRate), t.MarLastTitrationRateUnits,
                   TRY_CONVERT(DECIMAL(18,4), t.MarLastInfusionVolume), t.MarLastInfusionType, t.MarLastInfusionStatus,
                   TRY_CONVERT(DECIMAL(18,4), t.MarLastInfusionTotalIntakePrescription), TRY_CONVERT(DECIMAL(18,4), t.MarLastInfusionElapsedTime),
                   TRY_CONVERT(DECIMAL(18,4), t.MarLastInfusionTotalDose), t.MarLastInfusionBolusString, t.MarLastTitrationUser,
                   CONVERT(SYSNAME, 'PcsMarAct_MarLastTitration'), t.RowUpdateDateTime
            FROM {LINK}.PcsMarAct_MarLastTitration t
            INNER JOIN {LINK}.RegAcct_Main r ON r.SourceID = t.SourceID AND r.VisitID = t.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            LEFT JOIN {LINK}.PcsMarAct_MarMeds m ON m.SourceID = t.SourceID AND m.VisitID = t.VisitID
                AND m.MedicationPrescriptionNumberID = t.MarLastTitrationPrescriptionID AND m.MarBottleNumberID = t.MarLastTitrationBottleID
            WHERE t.MarLastTitrationDateTime >= @WindowStart AND t.MarLastTitrationDateTime < DATEADD(DAY, 1, @WindowEnd)

            UNION ALL
            SELECT CONVERT(NVARCHAR(250), CONCAT('BAG|', b.SourceID, '|', b.VisitID, '|', b.BagPrescriptionID, '|', b.BagBottleID, '|', b.BagMarActivityUrnID)),
                   b.SourceID, r.PatientID, b.VisitID, b.BagPrescriptionID, b.BagBottleID, CONVERT(VARCHAR(40), 'bag-last-documented'),
                   b.BagScheduleDateTimeID, b.BagLastDocumentedDateTime, m.MedicationTradeName, m.MedicationGenericName, NULL,
                   NULL, NULL, TRY_CONVERT(DECIMAL(18,4), b.BagLastDocumentedInfusionRate), b.BagPrescriptionRateUnits,
                   TRY_CONVERT(DECIMAL(18,4), b.BagLastDocumentedInfusionVolume), NULL, NULL, NULL, NULL, NULL, NULL,
                   b.BagLastDocumentedUser_UnvUserID, CONVERT(SYSNAME, 'PcsMarAct_BagInfusionLastDoc'), b.RowUpdateDateTime
            FROM {LINK}.PcsMarAct_BagInfusionLastDoc b
            INNER JOIN {LINK}.RegAcct_Main r ON r.SourceID = b.SourceID AND r.VisitID = b.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            LEFT JOIN {LINK}.PcsMarAct_MarMeds m ON m.SourceID = b.SourceID AND m.VisitID = b.VisitID
                AND m.MedicationPrescriptionNumberID = b.BagPrescriptionID AND m.MarBottleNumberID = b.BagBottleID
            WHERE b.BagLastDocumentedDateTime >= @WindowStart AND b.BagLastDocumentedDateTime < DATEADD(DAY, 1, @WindowEnd)

            UNION ALL
            SELECT CONVERT(NVARCHAR(250), CONCAT('ACTT|', t.SourceID, '|', t.VisitID, '|', t.MarActivityPrescriptionTitrationID, '|', t.MarActivityBottleTitrationID, '|', t.MarActivityTitrationUrnID)),
                   t.SourceID, r.PatientID, t.VisitID, t.MarActivityPrescriptionTitrationID, t.MarActivityBottleTitrationID,
                   CONVERT(VARCHAR(40), 'titration-activity'), t.MarActivityScheduleDateTimeTitrationID,
                   COALESCE(t.MarActivityTitrationDocumentationDateTime, t.MarActivityTitrationRecordDateTime),
                   m.MedicationTradeName, m.MedicationGenericName, NULL, NULL, rx.MarTitrationDoseUnits, NULL,
                   rx.MarTitrationRateUnits, NULL, t.MarActivityTitrationInfusionType, NULL, NULL, NULL, NULL,
                   t.MarActivityTitrationBolusString, t.MarActivityTitrationDocumentationUser_UnvUserID,
                   CONVERT(SYSNAME, 'PcsMarAct_MarActivityTitr'), t.RowUpdateDateTime
            FROM {LINK}.PcsMarAct_MarActivityTitr t
            INNER JOIN {LINK}.RegAcct_Main r ON r.SourceID=t.SourceID AND r.VisitID=t.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            LEFT JOIN {LINK}.PcsMarAct_MarMeds m ON m.SourceID=t.SourceID AND m.VisitID=t.VisitID
                AND m.MedicationPrescriptionNumberID=t.MarActivityPrescriptionTitrationID AND m.MarBottleNumberID=t.MarActivityBottleTitrationID
            LEFT JOIN {LINK}.PcsMarAct_MarRxs rx ON rx.SourceID=t.SourceID AND rx.VisitID=t.VisitID
                AND rx.MedicationPrescriptionNumberID=t.MarActivityPrescriptionTitrationID AND rx.MarBottleNumberID=t.MarActivityBottleTitrationID
            WHERE COALESCE(t.MarActivityTitrationDocumentationDateTime,t.MarActivityTitrationRecordDateTime) >= @WindowStart
              AND COALESCE(t.MarActivityTitrationDocumentationDateTime,t.MarActivityTitrationRecordDateTime) < DATEADD(DAY,1,@WindowEnd)
        ), Ranked AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY InfusionEventKey ORDER BY RowUpdateDateTime DESC) AS rn FROM InfusionEvents
        )
        INSERT #Build ({cols})
        SELECT InfusionEventKey, SourceID, CONVERT(NVARCHAR(50), PatientID), CONVERT(NVARCHAR(50), VisitID),
               CONVERT(NVARCHAR(100), PrescriptionID), CONVERT(NVARCHAR(100), BottleID), EventKind,
               CONVERT(DATETIME2(0), ScheduleDateTime), CONVERT(DATETIME2(0), AdministrationStartDateTime),
               CONVERT(NVARCHAR(300), MedicationTradeName), CONVERT(NVARCHAR(300), MedicationGenericName),
               CONVERT(NVARCHAR(200), Administration), Dose, CONVERT(NVARCHAR(60), DoseUnits), Rate,
               CONVERT(NVARCHAR(60), RateUnits), Volume, CONVERT(NVARCHAR(100), InfusionType),
               CONVERT(NVARCHAR(100), InfusionStatus), TotalIntake, ElapsedTime, TotalDose,
               CONVERT(NVARCHAR(500), BolusDescription), CONVERT(NVARCHAR(100), DocumentedByUserID),
               SourceTable, CONVERT(DATETIME2(0), RowUpdateDateTime), CONVERT(DATETIME2(0), SYSDATETIME())
        FROM Ranked WHERE rn = 1;""",
    }


def problem_spec():
    columns = [
        ("ProblemKey", "NVARCHAR(180)", False), ("SourceID", "VARCHAR(3)", True),
        ("PatientID", "NVARCHAR(50)", False), ("VisitID", "NVARCHAR(50)", True),
        ("ProblemRecordType", "VARCHAR(30)", False), ("ProblemInstanceID", "NVARCHAR(80)", False),
        ("ProblemCode", "NVARCHAR(100)", True), ("ProblemDictionaryID", "NVARCHAR(100)", True),
        ("ProblemName", "NVARCHAR(500)", True), ("ProblemDescription", "NVARCHAR(1000)", True),
        ("ProblemStatus", "NVARCHAR(100)", True), ("ProblemCategory", "NVARCHAR(100)", True),
        ("Priority", "NVARCHAR(60)", True), ("OnsetDateTime", "DATETIME2(0)", True),
        ("ResolvedDateTime", "DATETIME2(0)", True), ("EnteredDateTime", "DATETIME2(0)", True),
        ("EnteredByUserID", "NVARCHAR(100)", True), ("Deleted", "BIT", False),
        ("SourceTable", "SYSNAME", False), ("RowUpdateDateTime", "DATETIME2(0)", True),
        ("ExtractedOn", "DATETIME2(0)", False),
    ]
    cols = column_list(columns)
    return {
        "procedure": "usp_Build_FCAP1A_ProblemList", "output": "tbl_FCAP1A_ProblemList",
        "topic": "Problem List", "purpose": "Builds a dedicated longitudinal problem-list contract across active, pending, office, and health-concern sources.",
        "grain": "one row per problem or health-concern assertion", "columns": columns, "key": "ProblemKey", "time": "OnsetDateTime",
        "body": f"""        ;WITH Problems AS (
            SELECT CONVERT(NVARCHAR(180), CONCAT('ACTIVE|', p.SourceID, '|', p.PatientID, '|', p.ProblemInstanceID)) ProblemKey,
                   p.SourceID, p.PatientID, p.ProblemRegistrationOid_RegAcctID VisitID, CONVERT(VARCHAR(30), 'problem') ProblemRecordType,
                   CONVERT(NVARCHAR(80), p.ProblemInstanceID) ProblemInstanceID, p.ProblemDiagnosisCode_MisDxID ProblemCode,
                   p.ProblemDictionaryOid_MisPatProblemID ProblemDictionaryID,
                   COALESCE(p.ProblemSelectedDescription, d.Name, p.ProblemDisplay) ProblemName, p.ProblemFreeText ProblemDescription,
                   p.ProblemStatus, p.ProblemCategory, p.ProblemPriority Priority,
                   TRY_CONVERT(DATETIME2(0), p.ProblemOnsetDate) OnsetDateTime, p.ProblemDeletedDateTime ResolvedDateTime,
                   p.ProblemInitializedDateTime EnteredDateTime, p.ProblemInitializedBy_UnvUserID EnteredByUserID,
                   CONVERT(BIT, IIF(p.ProblemDeletedDateTime IS NULL, 0, 1)) Deleted,
                   CONVERT(SYSNAME, 'EmrPat_Problems') SourceTable, COALESCE(p.RowUpdateDateTime, pm.RowUpdateDateTime) RowUpdateDateTime
            FROM {LINK}.EmrPat_Problems p LEFT JOIN {LINK}.EmrPat_ProblemsMain pm ON pm.SourceID=p.SourceID AND pm.PatientID=p.PatientID INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=p.PatientID
            LEFT JOIN {LINK}.MisPatProblem_Main d ON d.SourceID=p.SourceID AND d.MisPatProblemID=p.ProblemDictionaryOid_MisPatProblemID
        ), Ranked AS (SELECT *, ROW_NUMBER() OVER(PARTITION BY ProblemKey ORDER BY RowUpdateDateTime DESC) rn FROM Problems)
        INSERT #Build ({cols})
        SELECT ProblemKey, SourceID, CONVERT(NVARCHAR(50),PatientID), CONVERT(NVARCHAR(50),VisitID), ProblemRecordType,
               ProblemInstanceID, CONVERT(NVARCHAR(100),ProblemCode), CONVERT(NVARCHAR(100),ProblemDictionaryID),
               CONVERT(NVARCHAR(500),ProblemName), CONVERT(NVARCHAR(1000),ProblemDescription), CONVERT(NVARCHAR(100),ProblemStatus),
               CONVERT(NVARCHAR(100),ProblemCategory), CONVERT(NVARCHAR(60),Priority), OnsetDateTime, ResolvedDateTime, EnteredDateTime,
               CONVERT(NVARCHAR(100),EnteredByUserID), Deleted, SourceTable, CONVERT(DATETIME2(0),RowUpdateDateTime), SYSDATETIME()
        FROM Ranked WHERE rn=1;""",
    }


def vaccines_spec():
    columns = [
        ("VaccineEventKey", "NVARCHAR(180)", False), ("SourceID", "VARCHAR(3)", True),
        ("PatientID", "NVARCHAR(50)", False), ("VaccineEventID", "INT", False),
        ("VaccineID", "NVARCHAR(80)", True), ("VaccineName", "NVARCHAR(300)", True),
        ("EventDateTime", "DATETIME2(0)", True), ("Given", "BIT", True),
        ("ReasonGivenID", "NVARCHAR(80)", True), ("ReasonNotGivenID", "NVARCHAR(80)", True),
        ("Route", "NVARCHAR(100)", True), ("AdministrationSiteID", "NVARCHAR(80)", True),
        ("Dose", "DECIMAL(18,4)", True), ("DoseUnits", "NVARCHAR(60)", True),
        ("LotNumber", "NVARCHAR(100)", True), ("LotExpirationDate", "DATE", True),
        ("ManufacturerID", "NVARCHAR(80)", True), ("NdcID", "NVARCHAR(80)", True),
        ("CvxCode", "NVARCHAR(80)", True), ("FacilityID", "NVARCHAR(60)", True),
        ("EnteredByUserID", "NVARCHAR(100)", True), ("Deleted", "BIT", False),
        ("RowUpdateDateTime", "DATETIME2(0)", True), ("ExtractedOn", "DATETIME2(0)", False),
    ]
    cols=column_list(columns)
    return {
        "procedure":"usp_Build_FCAP1A_Vaccines","output":"tbl_FCAP1A_Vaccines","topic":"Vaccines",
        "purpose":"Builds a dedicated vaccine administration subset with dose, lot, route, CVX, and not-given reason.",
        "grain":"one row per vaccine event and dose","columns":columns,"key":"VaccineEventKey","time":"EventDateTime",
        "body":f"""        ;WITH Ranked AS (
            SELECT v.*, vd.VaccineDose, vd.VaccineDoseUnits, vd.VaccineDoseInjectionSite_MisAdminSiteID,
                   vd.VaccineDoseLotNumber, vd.VaccineDoseLotExpirationDate, d.Name VaccineName, d.CvxCode_MisCvxCodeID,
                   ROW_NUMBER() OVER(PARTITION BY v.SourceID,v.PatientID,v.VaccineEventID
                                     ORDER BY vd.VaccineDoseUrnID,v.RowUpdateDateTime DESC) rn
            FROM {LINK}.EmrPat_Vaccines v
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=v.PatientID
            LEFT JOIN {LINK}.EmrPat_VaccinesDoses vd ON vd.SourceID=v.SourceID AND vd.PatientID=v.PatientID
                AND vd.Vaccine_MisVaccineID=v.Vaccine_MisVaccineID AND vd.VaccineEventID=v.VaccineEventID
            LEFT JOIN {LINK}.MisVaccine_Main d ON d.SourceID=v.SourceID AND d.MisVaccineID=v.Vaccine_MisVaccineID
            WHERE COALESCE(v.VaccineDate,v.VaccineEnteredDate) >= @WindowStart
              AND COALESCE(v.VaccineDate,v.VaccineEnteredDate) < DATEADD(DAY,1,@WindowEnd)
        )
        INSERT #Build ({cols})
        SELECT CONVERT(NVARCHAR(180),CONCAT(SourceID,'|',PatientID,'|',VaccineEventID)),SourceID,CONVERT(NVARCHAR(50),PatientID),
               VaccineEventID,CONVERT(NVARCHAR(80),Vaccine_MisVaccineID),CONVERT(NVARCHAR(300),VaccineName),
               CONVERT(DATETIME2(0),COALESCE(VaccineDate,VaccineEnteredDate)),
               CONVERT(BIT,CASE WHEN VaccineGiven IN ('Y','YES','1') THEN 1 WHEN VaccineGiven IN ('N','NO','0') THEN 0 END),
               CONVERT(NVARCHAR(80),VaccineReasonGiven_MisImmReasonID),CONVERT(NVARCHAR(80),VaccineReasonNotGiven_MisImmReasonID),
               CONVERT(NVARCHAR(100),VaccineRoute),CONVERT(NVARCHAR(80),VaccineDoseInjectionSite_MisAdminSiteID),
               TRY_CONVERT(DECIMAL(18,4),VaccineDose),CONVERT(NVARCHAR(60),VaccineDoseUnits),CONVERT(NVARCHAR(100),VaccineDoseLotNumber),
               TRY_CONVERT(DATE,VaccineDoseLotExpirationDate),CONVERT(NVARCHAR(80),VaccineManufacturer_MisMfrID),
               CONVERT(NVARCHAR(80),VaccineNdcNumber_MisNdcID),CONVERT(NVARCHAR(80),CvxCode_MisCvxCodeID),
               CONVERT(NVARCHAR(60),VaccineFacility_MisFacID),CONVERT(NVARCHAR(100),VaccineEnteredBy_UnvUserID),
               CONVERT(BIT,IIF(VaccineDeleted IN ('Y','YES','1'),1,0)),CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()
        FROM Ranked WHERE rn=1;""",
    }


def surgery_spec():
    columns=[
        ("SurgicalCaseKey","NVARCHAR(160)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("VisitID","NVARCHAR(50)",True),("SurgicalCaseID","NVARCHAR(80)",False),("SurgeryStartDateTime","DATETIME2(0)",True),
        ("ScheduledDateTime","DATETIME2(0)",True),("ArrivalDateTime","DATETIME2(0)",True),("OperatingRoomID","NVARCHAR(80)",True),
        ("SurgicalAreaID","NVARCHAR(80)",True),("CaseTypeID","NVARCHAR(80)",True),("SurgeonID","NVARCHAR(100)",True),
        ("AnesthesiologistID","NVARCHAR(100)",True),("AnesthesiaTypeID","NVARCHAR(80)",True),("TotalDurationMinutes","INT",True),
        ("ProcedureID","NVARCHAR(100)",True),("ProcedureDescription","NVARCHAR(1000)",True),("ProcedureStartDateTime","DATETIME2(0)",True),
        ("ProcedureEndDateTime","DATETIME2(0)",True),("ProcedureSide","NVARCHAR(60)",True),("WoundClass","NVARCHAR(100)",True),
        ("ImplantCount","INT",False),("SchedulerNotes","NVARCHAR(2000)",True),("Delayed","BIT",True),
        ("RowUpdateDateTime","DATETIME2(0)",True),("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_Surgical_Cases_Extended","output":"tbl_FCAP1A_Surgical_Cases_Extended",
        "topic":"Surgical Cases","purpose":"Builds surgical case headers enriched with appointment, primary actual procedure, operative times, and implant counts.",
        "grain":"one row per surgical case","columns":columns,"key":"SurgicalCaseKey","time":"SurgeryStartDateTime",
        "body":f"""        INSERT #Build ({cols})
        SELECT CONVERT(NVARCHAR(160),CONCAT(s.SourceID,'|',s.CwsApptID)),s.SourceID,CONVERT(NVARCHAR(50),a.PatientID),
               CONVERT(NVARCHAR(50),a.VisitID),CONVERT(NVARCHAR(80),s.CwsApptID),
               CONVERT(DATETIME2(0),COALESCE(st.ActualProcedureSurgeonDateTimeFromID,pt.ActualProcedureStart,a.DateTime,s.EchartDateTime)),CONVERT(DATETIME2(0),a.DateTime),
               CONVERT(DATETIME2(0),a.ArrivalDateTime),CONVERT(NVARCHAR(80),s.OperatingRoom_CwsResRoomID),
               CONVERT(NVARCHAR(80),s.SurgicalArea_SurAreaDestID),CONVERT(NVARCHAR(80),s.Type_SurCaseTypeID),
               CONVERT(NVARCHAR(100),s.Surgeon_UnvUserID),CONVERT(NVARCHAR(100),s.Anesthesiologist_UnvUserID),
               CONVERT(NVARCHAR(80),s.AnesthesiaType_MisAnesID),TRY_CONVERT(INT,s.OperationRoomTotalDuration),
               CONVERT(NVARCHAR(100),pt.ActualProcedure_CwsApptProcID),CONVERT(NVARCHAR(1000),pt.ActualProcedureDescription),
               CONVERT(DATETIME2(0),COALESCE(st.ActualProcedureSurgeonDateTimeFromID,pt.ActualProcedureStart)),CONVERT(DATETIME2(0),COALESCE(st.ActualProcedureSurgeonDateTimeThrough,pt.ActualProcedureEnd)),
               CONVERT(NVARCHAR(60),pt.ActualProcedureSide),CONVERT(NVARCHAR(100),pt.ActualProcedureWoundClass),
               CONVERT(INT,ISNULL(ic.ImplantCount,0)),CONVERT(NVARCHAR(2000),s.SchedulerNotes),
               CONVERT(BIT,CASE WHEN s.OperationDelayYn IN ('Y','YES','1') THEN 1 WHEN s.OperationDelayYn IN ('N','NO','0') THEN 0 END),
               CONVERT(DATETIME2(0),s.RowUpdateDateTime),SYSDATETIME()
        FROM {LINK}.SurCase_Main s
        INNER JOIN {LINK}.CwsAppt_Main a ON a.SourceID=s.SourceID AND a.CwsApptID=s.CwsApptID
        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
        OUTER APPLY(SELECT TOP(1) p.* FROM {LINK}.SurCase_ActualProcs p
                    WHERE p.SourceID=s.SourceID AND p.CwsApptID=s.CwsApptID
                    ORDER BY CASE WHEN p.ActualProcedurePrimary IN ('Y','YES','1') THEN 0 ELSE 1 END,p.SortOrder,p.ActualProcedureUrnID) pt
        OUTER APPLY(SELECT TOP(1) x.ActualProcedureSurgeonDateTimeFromID,x.ActualProcedureSurgeonDateTimeThrough FROM {LINK}.SurCase_ActualProcSurgTimes x
                    WHERE x.SourceID=s.SourceID AND x.CwsApptID=s.CwsApptID AND x.ActualProcedureUrnID=pt.ActualProcedureUrnID
                    ORDER BY x.ActualProcedureSurgeonDateTimeFromID) st
        OUTER APPLY(SELECT COUNT_BIG(*) ImplantCount FROM {LINK}.SurCase_Implant i
                    WHERE i.SourceID=s.SourceID AND i.CwsApptID=s.CwsApptID) ic
        WHERE COALESCE(a.DateTime,s.EchartDateTime) >= @WindowStart
          AND COALESCE(a.DateTime,s.EchartDateTime) < DATEADD(DAY,1,@WindowEnd);"""}


def social_spec():
    columns=[
        ("SocialHistoryKey","NVARCHAR(220)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("VisitID","NVARCHAR(50)",True),("QueryID","NVARCHAR(100)",False),("Question","NVARCHAR(1000)",True),
        ("Response","NVARCHAR(2000)",True),("ResponseSequence","INT",True),("ResponseScope","VARCHAR(20)",False),
        ("RecordedDateTime","DATETIME2(0)",True),("SourceTable","SYSNAME",False),("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_SocialHistory","output":"tbl_FCAP1A_SocialHistory","topic":"Social History",
        "purpose":"Builds social-history responses by resolving configured smoking/social query IDs and the query dictionary.",
        "grain":"one row per patient social-history response","columns":columns,"key":"SocialHistoryKey","time":"RecordedDateTime",
        "body":f"""        ;WITH SocialQueries AS (
            SELECT q.SourceID,q.MisQryID,q.Text,q.Mnemonic FROM {LINK}.MisQry_Main q
            WHERE UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%SOCIAL HIST%'
               OR UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%SMOK%'
               OR UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%TOBACCO%'
               OR UPPER(CONCAT_WS(' ',q.Mnemonic,q.Text)) LIKE '%ALCOHOL%'
            ), Responses AS (
            SELECT CONVERT(NVARCHAR(220),CONCAT('PAT|',r.SourceID,'|',r.PatientID,'|',r.QueryID,'|0')) SocialHistoryKey,
                   r.SourceID,r.PatientID,CONVERT(NVARCHAR(50),NULL) VisitID,r.QueryID,q.Text Question,r.QueryResponse Response,
                   CONVERT(INT,NULL) ResponseSequence,CONVERT(VARCHAR(20),'patient') ResponseScope,r.RowUpdateDateTime RecordedDateTime,
                   CONVERT(SYSNAME,'HimRec_CustomDataQueries_Queries') SourceTable
            FROM {LINK}.HimRec_CustomDataQueries_Queries r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('PATM|',r.SourceID,'|',r.PatientID,'|',r.QueryID,'|',r.QuerySeqID)),r.SourceID,r.PatientID,NULL,
                   r.QueryID,q.Text,r.QueryResponse,r.QuerySeqID,'patient',r.RowUpdateDateTime,'HimRec_CustomDataQueries_QueriesMult'
            FROM {LINK}.HimRec_CustomDataQueries_QueriesMult r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('VIS|',r.SourceID,'|',r.VisitID,'|',r.QueryID,'|0')),r.SourceID,a.PatientID,r.VisitID,
                   r.QueryID,q.Text,r.QueryResponse,NULL,'visit',r.RowUpdateDateTime,'RegAcct_CustomDataQueries_Queries'
            FROM {LINK}.RegAcct_CustomDataQueries_Queries r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN {LINK}.RegAcct_Main a ON a.SourceID=r.SourceID AND a.VisitID=r.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('VISM|',r.SourceID,'|',r.VisitID,'|',r.QueryID,'|',r.QuerySeqID)),r.SourceID,a.PatientID,r.VisitID,
                   r.QueryID,q.Text,r.QueryResponse,r.QuerySeqID,'visit',r.RowUpdateDateTime,'RegAcct_CustomDataQueries_QueriesMult'
            FROM {LINK}.RegAcct_CustomDataQueries_QueriesMult r INNER JOIN SocialQueries q ON q.SourceID=r.SourceID AND q.MisQryID=r.QueryID
            INNER JOIN {LINK}.RegAcct_Main a ON a.SourceID=r.SourceID AND a.VisitID=r.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
        ), Ranked AS(SELECT *,ROW_NUMBER() OVER(PARTITION BY SocialHistoryKey ORDER BY RecordedDateTime DESC) rn FROM Responses)
        INSERT #Build ({cols})
        SELECT SocialHistoryKey,SourceID,CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(NVARCHAR(100),QueryID),
               CONVERT(NVARCHAR(1000),Question),CONVERT(NVARCHAR(2000),Response),ResponseSequence,ResponseScope,
               CONVERT(DATETIME2(0),RecordedDateTime),SourceTable,SYSDATETIME() FROM Ranked WHERE rn=1;"""}


def ob_spec():
    columns=[
        ("PregnancyKey","NVARCHAR(180)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("VisitID","NVARCHAR(50)",True),("PregnancyCountID","INT",False),("PregnancyActive","BIT",True),
        ("PregnancyStatus","NVARCHAR(100)",True),("LastMenstrualPeriod","DATE",True),("ConceptionDate","DATE",True),
        ("UltrasoundDate","DATE",True),("EstimatedDeliveryDate","DATE",True),("DeliveryDateTime","DATETIME2(0)",True),
        ("FetalCount","INT",True),("InitialWeight","DECIMAL(18,4)",True),("InitialWeightUnit","NVARCHAR(40)",True),
        ("CompletedByUserID","NVARCHAR(100)",True),("CompletedDateTime","DATETIME2(0)",True),
        ("ActualDeliveryCaptured","BIT",False),("CoverageNote","NVARCHAR(500)",False),
        ("RowUpdateDateTime","DATETIME2(0)",True),("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_OBDelivery","output":"tbl_FCAP1A_OBDelivery","topic":"OB / Delivery",
        "purpose":"Builds pregnancy episodes and visit linkage; explicitly distinguishes estimated delivery from unavailable structured actual-delivery time.",
        "grain":"one row per pregnancy episode","columns":columns,"key":"PregnancyKey","time":"DeliveryDateTime",
        "body":f"""        INSERT #Build ({cols})
        SELECT CONVERT(NVARCHAR(180),CONCAT(p.SourceID,'|',p.PatientID,'|',p.PregnancyCountID)),p.SourceID,
               CONVERT(NVARCHAR(50),p.PatientID),CONVERT(NVARCHAR(50),v.PregnancyVisit_RegAcctID),p.PregnancyCountID,
               CONVERT(BIT,CASE WHEN p.PregnancyActive IN ('Y','YES','1') THEN 1 WHEN p.PregnancyActive IN ('N','NO','0') THEN 0 END),
               CONVERT(NVARCHAR(100),p.PregnancyStatus),TRY_CONVERT(DATE,p.LastMenstrualPeriod),TRY_CONVERT(DATE,p.ConceptionDate),
               TRY_CONVERT(DATE,p.UltrasoundDate),TRY_CONVERT(DATE,COALESCE(p.ManualEstimatedDeliveryDate,p.EstimatedDeliveryDate)),
               CONVERT(DATETIME2(0),NULL),TRY_CONVERT(INT,p.FetalCount),TRY_CONVERT(DECIMAL(18,4),p.ObstetricsInitialWeight),
               CONVERT(NVARCHAR(40),p.ObstetricsInitialWeightAlternateUnit),CONVERT(NVARCHAR(100),p.CompletedByUser),
               CONVERT(DATETIME2(0),p.CompletedByDateTime),CONVERT(BIT,0),
               CONVERT(NVARCHAR(500),N'Pregnancy episode is structured; actual labour/delivery timestamp requires delivery or clinical-document source confirmation.'),
               CONVERT(DATETIME2(0),COALESCE(pm.RowUpdateDateTime,p.RowUpdateDateTime)),SYSDATETIME()
        FROM {LINK}.AmbPatCm_PregnancyData p LEFT JOIN {LINK}.AmbPatCm_PregnancyMain pm ON pm.SourceID=p.SourceID AND pm.PatientID=p.PatientID INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=p.PatientID
        OUTER APPLY(SELECT TOP(1) x.PregnancyVisit_RegAcctID FROM {LINK}.AmbPatCm_PregnancyVisitLog x
                    WHERE x.SourceID=p.SourceID AND x.PatientID=p.PatientID AND x.PregnancyCountID=p.PregnancyCountID
                    ORDER BY x.RowUpdateDateTime DESC,x.PregnancyVisitUrnID DESC)v
        WHERE COALESCE(p.CompletedByDateTime,p.ConceptionDate,p.LastMenstrualPeriod,p.EstimatedDeliveryDate,p.RowUpdateDateTime) < DATEADD(DAY,1,@WindowEnd);"""}


def device_spec():
    columns=[
        ("DeviceEventKey","NVARCHAR(220)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("VisitID","NVARCHAR(50)",True),("DeviceIdentifier","NVARCHAR(160)",True),("SerialNumber","NVARCHAR(160)",True),
        ("LotNumber","NVARCHAR(160)",True),("CatalogNumber","NVARCHAR(160)",True),("ManufacturerID","NVARCHAR(100)",True),
        ("DeviceDescription","NVARCHAR(1000)",True),("ImplantDateTime","DATETIME2(0)",True),("ExplantDateTime","DATETIME2(0)",True),
        ("ExpirationDate","DATE",True),("Quantity","DECIMAL(18,4)",True),("Status","NVARCHAR(100)",True),
        ("DeviceSource","VARCHAR(30)",False),("Comment","NVARCHAR(2000)",True),("RowUpdateDateTime","DATETIME2(0)",True),
        ("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_MedicalDevices","output":"tbl_FCAP1A_MedicalDevices","topic":"Medical Device",
        "purpose":"Builds patient implant registry, surgical implant, and loaned-device history into one typed device contract.",
        "grain":"one row per device status interval or implantation event","columns":columns,"key":"DeviceEventKey","time":"ImplantDateTime",
        "body":f"""        ;WITH Devices AS(
            SELECT CONVERT(NVARCHAR(220),CONCAT('PAT|',d.SourceID,'|',d.PatientID,'|',d.ImplantableDeviceIdentifier_MisUniqueDevIdID,'|',d.ImplantableDeviceDateID)) DeviceEventKey,
                   d.SourceID,d.PatientID,CONVERT(NVARCHAR(50),NULL) VisitID,d.ImplantableDeviceIdentifier_MisUniqueDevIdID DeviceIdentifier,
                   CONVERT(NVARCHAR(160),NULL) SerialNumber,CONVERT(NVARCHAR(160),NULL) LotNumber,CONVERT(NVARCHAR(160),NULL) CatalogNumber,
                   CONVERT(NVARCHAR(100),NULL) ManufacturerID,CONVERT(NVARCHAR(1000),NULL) DeviceDescription,
                   d.ImplantableDeviceDateID ImplantDateTime,CONVERT(DATETIME2(0),NULL) ExplantDateTime,CONVERT(DATE,NULL) ExpirationDate,
                   TRY_CONVERT(DECIMAL(18,4),d.ImplantableDeviceQuantity) Quantity,CONVERT(NVARCHAR(100),d.ImplantableDeviceSourceID) Status,
                   CONVERT(VARCHAR(30),'patient-registry') DeviceSource,d.ImplantableDeviceComment Comment,d.RowUpdateDateTime
            FROM {LINK}.EmrPat_ImplDev d INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=d.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('SURG|',i.SourceID,'|',i.CwsApptID,'|',i.ImplantsUrnID)),i.SourceID,a.PatientID,a.VisitID,
                   i.ImplantDeviceIdentifier_MisUniqueDevIdID,i.ImplantsSerialNumber,i.ImplantsLotNumber,i.ImplantsCatalogNumber,i.ImplantsManufacturer_MisMfrID,
                   i.ImplantsDescription,a.DateTime,NULL,i.ImplantsExpirationDate,TRY_CONVERT(DECIMAL(18,4),i.ImplantsQuantityUsed),
                   CONVERT(NVARCHAR(100),IIF(i.ImplantDeviceNotAssociated IN ('Y','YES','1'),'not-associated','implanted')),
                   CONVERT(VARCHAR(30),'surgical-implant'),i.ImplantsComment,i.RowUpdateDateTime
            FROM {LINK}.SurCase_Implant i INNER JOIN {LINK}.CwsAppt_Main a ON a.SourceID=i.SourceID AND a.CwsApptID=i.CwsApptID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
        ),Ranked AS(SELECT *,ROW_NUMBER() OVER(PARTITION BY DeviceEventKey ORDER BY RowUpdateDateTime DESC)rn FROM Devices)
        INSERT #Build ({cols})
        SELECT DeviceEventKey,SourceID,CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(NVARCHAR(160),DeviceIdentifier),
               CONVERT(NVARCHAR(160),SerialNumber),CONVERT(NVARCHAR(160),LotNumber),CONVERT(NVARCHAR(160),CatalogNumber),
               CONVERT(NVARCHAR(100),ManufacturerID),CONVERT(NVARCHAR(1000),DeviceDescription),CONVERT(DATETIME2(0),ImplantDateTime),
               CONVERT(DATETIME2(0),ExplantDateTime),TRY_CONVERT(DATE,ExpirationDate),Quantity,CONVERT(NVARCHAR(100),Status),DeviceSource,
               CONVERT(NVARCHAR(2000),Comment),CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME() FROM Ranked WHERE rn=1;"""}


def genomics_spec():
    columns=[
        ("GenomicResultKey","NVARCHAR(220)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("VisitID","NVARCHAR(50)",True),("OrderMnemonic","NVARCHAR(160)",True),("OrderName","NVARCHAR(500)",True),
        ("DataURN","NVARCHAR(160)",True),("ResultDateTime","DATETIME2(0)",True),("Result","NVARCHAR(MAX)",True),
        ("LastValue","NVARCHAR(2000)",True),("Confidential","BIT",True),("ReportAvailable","BIT",True),
        ("LabLinkAvailable","BIT",True),("SourceClass","NVARCHAR(100)",True),("RowUpdateDateTime","DATETIME2(0)",True),
        ("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_Genomics","output":"tbl_FCAP1A_Genomics","topic":"Genomics",
        "purpose":"Builds structured genetic result summaries from the patient-summary genetic-results source.",
        "grain":"one row per genomic result","columns":columns,"key":"GenomicResultKey","time":"ResultDateTime",
        "body":f"""        ;WITH Ranked AS(
            SELECT g.*,ROW_NUMBER() OVER(PARTITION BY g.SourceID,g.PatientID,g.VisitID,g.GeneticDataUrn
                                         ORDER BY g.RowUpdateDateTime DESC)rn
            FROM {LINK}.EmrPatSum_GenResults g INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=g.PatientID
            WHERE COALESCE(g.GeneticDataTime,g.RowUpdateDateTime)>=@WindowStart
              AND COALESCE(g.GeneticDataTime,g.RowUpdateDateTime)<DATEADD(DAY,1,@WindowEnd)
        )
        INSERT #Build ({cols})
        SELECT CONVERT(NVARCHAR(220),CONCAT(SourceID,'|',PatientID,'|',VisitID,'|',GeneticDataUrn)),SourceID,
               CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(NVARCHAR(160),GeneticOrderMnemonicID),
               CONVERT(NVARCHAR(500),GeneticOrderName),CONVERT(NVARCHAR(160),GeneticDataUrn),CONVERT(DATETIME2(0),GeneticDataTime),
               CONVERT(NVARCHAR(MAX),GeneticResult),CONVERT(NVARCHAR(2000),GeneticLastValue),
               CONVERT(BIT,CASE WHEN GeneticConfidential IN('Y','YES','1') THEN 1 WHEN GeneticConfidential IN('N','NO','0') THEN 0 END),
               CONVERT(BIT,CASE WHEN GeneticReportFlag IN('Y','YES','1') THEN 1 WHEN GeneticReportFlag IN('N','NO','0') THEN 0 END),
               CONVERT(BIT,CASE WHEN GeneticLabLinkFlag IN('Y','YES','1') THEN 1 WHEN GeneticLabLinkFlag IN('N','NO','0') THEN 0 END),
               CONVERT(NVARCHAR(100),GeneticSourceClass),CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()
        FROM Ranked WHERE rn=1;"""}


def reports_spec():
    columns=[
        ("ReportKey","NVARCHAR(220)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("VisitID","NVARCHAR(50)",True),("ReportDateTime","DATETIME2(0)",True),("ReportType","NVARCHAR(100)",True),
        ("ReportIdentifier","NVARCHAR(200)",True),("Status","NVARCHAR(100)",True),("SpecialtyID","NVARCHAR(80)",True),
        ("LastValue","NVARCHAR(2000)",True),("Confidential","BIT",True),("ResultReference","NVARCHAR(1000)",True),
        ("SourceTable","SYSNAME",False),("RowUpdateDateTime","DATETIME2(0)",True),("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_OtherReports","output":"tbl_FCAP1A_OtherReports","topic":"Other Clinical Reports",
        "purpose":"Consolidates patient-summary documents and account report references not owned by a more specific domain.",
        "grain":"one row per report or document version","columns":columns,"key":"ReportKey","time":"ReportDateTime",
        "body":f"""        ;WITH Reports AS(
            SELECT CONVERT(NVARCHAR(220),CONCAT('IMG|',i.SourceID,'|',i.VisitID,'|',i.DataUrnID,'|',i.ImageKeyID)),i.SourceID,r.PatientID,i.VisitID,
                   COALESCE(i.ImageDate,i.RowUpdateDateTime),i.ImageInterpretationType,i.ImageIdentifier,i.ImageStatus,NULL,NULL,NULL,i.ImageUrl,
                   'EmrAcctRep_Images',i.RowUpdateDateTime
            FROM {LINK}.EmrAcctRep_Images i INNER JOIN {LINK}.RegAcct_Main r ON r.SourceID=i.SourceID AND r.VisitID=i.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            WHERE COALESCE(i.ImageDate,i.RowUpdateDateTime)>=@WindowStart AND COALESCE(i.ImageDate,i.RowUpdateDateTime)<DATEADD(DAY,1,@WindowEnd)
        ),Ranked AS(SELECT *,ROW_NUMBER()OVER(PARTITION BY ReportKey ORDER BY RowUpdateDateTime DESC)rn FROM Reports)
        INSERT #Build ({cols})
        SELECT ReportKey,SourceID,CONVERT(NVARCHAR(50),PatientID),CONVERT(NVARCHAR(50),VisitID),CONVERT(DATETIME2(0),ReportDateTime),
               CONVERT(NVARCHAR(100),ReportType),CONVERT(NVARCHAR(200),ReportIdentifier),CONVERT(NVARCHAR(100),Status),
               CONVERT(NVARCHAR(80),SpecialtyID),CONVERT(NVARCHAR(2000),LastValue),Confidential,CONVERT(NVARCHAR(1000),ResultReference),
               SourceTable,CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()FROM Ranked WHERE rn=1;"""}


def registries_spec():
    columns=[
        ("RegistryEventKey","NVARCHAR(220)",False),("SourceID","VARCHAR(3)",True),("PatientID","NVARCHAR(50)",False),
        ("RegistryEventType","VARCHAR(30)",False),("ObservationCode","NVARCHAR(160)",True),("ObservationValue","NVARCHAR(2000)",True),
        ("EnrollmentDateTime","DATETIME2(0)",True),("ObservationDateTime","DATETIME2(0)",True),("Active","BIT",True),
        ("AbnormalFlags","NVARCHAR(100)",True),("CarePlan","NVARCHAR(2000)",True),("SourceTable","SYSNAME",False),
        ("RowUpdateDateTime","DATETIME2(0)",True),("ExtractedOn","DATETIME2(0)",False),
    ]
    cols=column_list(columns)
    return {"procedure":"usp_Build_FCAP1A_Registries","output":"tbl_FCAP1A_Registries","topic":"Registries & Analytics",
        "purpose":"Builds registry membership and longitudinal registry laboratory observations.",
        "grain":"one row per registry membership or observation","columns":columns,"key":"RegistryEventKey","time":"EnrollmentDateTime",
        "body":f"""        ;WITH RegistryEvents AS(
            SELECT CONVERT(NVARCHAR(220),CONCAT('MEMBER|',r.SourceID,'|',r.PatientID))RegistryEventKey,r.SourceID,r.PatientID,
                   CONVERT(VARCHAR(30),'membership')RegistryEventType,CONVERT(NVARCHAR(160),NULL)ObservationCode,
                   CONVERT(NVARCHAR(2000),r.Problems)ObservationValue,r.RowUpdateDateTime EnrollmentDateTime,CONVERT(DATETIME2(0),NULL)ObservationDateTime,
                   CONVERT(BIT,CASE WHEN r.Active IN('Y','YES','1')THEN 1 WHEN r.Active IN('N','NO','0')THEN 0 END)Active,
                   CONVERT(NVARCHAR(100),NULL)AbnormalFlags,CONVERT(NVARCHAR(2000),r.CarePlan)CarePlan,CONVERT(SYSNAME,'EmrPatRegistry_Main')SourceTable,r.RowUpdateDateTime
            FROM {LINK}.EmrPatRegistry_Main r INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('LAB|',r.SourceID,'|',r.PatientID,'|',r.LaboratoryTestID,'|',CONVERT(VARCHAR(33),r.LaboratoryDateTime,126))),
                   r.SourceID,r.PatientID,'laboratory',r.LaboratoryTestID,CONVERT(NVARCHAR(2000),r.LaboratoryValue),NULL,r.LaboratoryDateTime,NULL,
                   r.LaboratoryAbnormalFlags,NULL,'EmrPatRegistry_LastLabResults',r.RowUpdateDateTime
            FROM {LINK}.EmrPatRegistry_LastLabResults r INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            WHERE COALESCE(r.LaboratoryDateTime,r.RowUpdateDateTime)>=@WindowStart AND COALESCE(r.LaboratoryDateTime,r.RowUpdateDateTime)<DATEADD(DAY,1,@WindowEnd)
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('CHRONIC|',r.SourceID,'|',r.PatientID)),r.SourceID,r.PatientID,'chronic-condition-index',
                   NULL,NULL,r.RowUpdateDateTime,NULL,NULL,NULL,NULL,'EmrPatRegistry_ChronicConds',r.RowUpdateDateTime
            FROM {LINK}.EmrPatRegistry_ChronicConds r INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
        ),Ranked AS(SELECT *,ROW_NUMBER()OVER(PARTITION BY RegistryEventKey ORDER BY RowUpdateDateTime DESC)rn FROM RegistryEvents)
        INSERT #Build ({cols})
        SELECT RegistryEventKey,SourceID,CONVERT(NVARCHAR(50),PatientID),RegistryEventType,CONVERT(NVARCHAR(160),ObservationCode),
               CONVERT(NVARCHAR(2000),ObservationValue),CONVERT(DATETIME2(0),EnrollmentDateTime),CONVERT(DATETIME2(0),ObservationDateTime),
               Active,CONVERT(NVARCHAR(100),AbnormalFlags),CONVERT(NVARCHAR(2000),CarePlan),SourceTable,
               CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()FROM Ranked WHERE rn=1;"""}


def all_specs():
    structured_gap = "Relational order/report evidence only; validate the owning system before treating it as a structured measurement set."
    external_gap = "Relational event metadata only; binary media and authoritative DICOM/device headers remain in the external clinical system."
    specs = [appointments_spec(), problem_spec(), order_spec("Medication Orders", "MedicationOrders", True),
             order_spec("Procedure Orders", "ProcedureOrders", False), vaccines_spec(), infusion_spec(),
             surgery_spec(), social_spec(), ob_spec(), device_spec(), reports_spec(), registries_spec()]
    generic = [
        ("ecgecho","ECG & Echo","ECGAndEcho",["ECG","EKG","ELECTROCARDIOGRAM","ECHOCARDIOGRAM"],False,structured_gap,"one row per ECG or echo order/report evidence"),
        ("genomics","Genomics","Genomics",["GENOMIC","GENETIC","MOLECULAR","DNA"],False,structured_gap,"one row per genomic order/report evidence"),
        ("pft","Pulmonary Function Test","PulmonaryFunctionTests",["PULMONARY FUNCTION","SPIROMETRY"," PFT"],False,structured_gap,"one row per PFT order/report evidence"),
        ("rhc","RHC Measurements","RHCMeasurements",["RIGHT HEART CATH","HEMODYNAMIC","RHC"],False,structured_gap,"one row per catheterisation order/report evidence"),
        ("dicom","DICOM Header","DICOMHeaders",["DICOM","PACS"],True,external_gap,"one row per relational image/report reference"),
        ("ct","CT","CTImaging",["CT SCAN","COMPUTED TOMOGRAPHY"],True,external_gap,"one row per CT order/report evidence"),
        ("pet","PET","PETImaging",["PET SCAN","POSITRON EMISSION"],True,external_gap,"one row per PET order/report evidence"),
        ("mri","MRI","MRIImaging",["MRI","MAGNETIC RESONANCE"],True,external_gap,"one row per MRI order/report evidence"),
        ("echo","Echocardiogram","Echocardiograms",["ECHOCARDIOGRAM","CARDIAC ECHO"],False,structured_gap,"one row per echocardiogram order/report evidence"),
        ("gi","GI - Endoscopy","GIEndoscopy",["ENDOSCOPY","COLONOSCOPY","GASTROSCOPY","SIGMOIDOSCOPY"],False,structured_gap,"one row per endoscopy order/report evidence"),
        ("us","Ultrasound","UltrasoundImaging",["ULTRASOUND","SONOGRAM","SONOGRAPHY"],True,external_gap,"one row per ultrasound order/report evidence"),
        ("cath","Cardiology (Cath) Imaging","CardiologyCathImaging",["CARDIAC CATH","CORONARY ANGIO","CATHETERIZATION"],True,external_gap,"one row per cath order/report evidence"),
        ("mammo","Mammography","Mammography",["MAMMOGRAM","MAMMOGRAPHY"],True,external_gap,"one row per mammography order/report evidence"),
        ("dpath","Digital Pathology","DigitalPathology",["DIGITAL PATHOLOGY","WHOLE SLIDE"],True,external_gap,"one row per digital-pathology order/report reference"),
        ("derm","Dermatology Imaging","DermatologyImaging",["DERMATOLOGY IMAGE","CLINICAL PHOTO","SKIN PHOTO"],True,external_gap,"one row per dermatology-image reference"),
        ("eye","Eye Imaging (Fundus, OCT)","EyeImaging",["FUNDUS","OPTICAL COHERENCE","OCT EYE","RETINAL IMAGE"],True,external_gap,"one row per ophthalmic imaging order/report evidence"),
        ("xray","X-Ray","XRayImaging",["X-RAY","XRAY","RADIOGRAPH"],True,external_gap,"one row per radiography order/report evidence"),
        ("biorepo","Bio-repositories","Biorepository",["BIOBANK","BIOREPOSITORY","ALIQUOT"],True,external_gap,"one row per biorepository order/report reference"),
        ("eeg","Electrophysiology (EEG)","EEG",["EEG","ELECTROENCEPHAL"],True,external_gap,"one row per EEG order/report evidence"),
        ("surgvideo","Surgical Video","SurgicalVideo",["SURGICAL VIDEO","OPERATIVE VIDEO"],True,external_gap,"one row per surgical-video reference"),
    ]
    specs.extend(generic_spec(*row) for row in generic)
    return specs


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    specs = all_specs()
    if len(specs) != 32:
        raise SystemExit(f"Expected 32 remaining-topic procedures, found {len(specs)}")
    for spec in specs:
        path = os.path.join(OUT_DIR, spec["procedure"] + ".sql")
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(render(spec))
    print("wrote", len(specs), "dedicated topic procedures")


if __name__ == "__main__":
    main()
