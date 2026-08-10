USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_Infusions
    Purpose   : Builds infusion documentation, titration, and bag events from the MAR activity family.
    Grain     : one row per documented infusion or titration event
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_Infusions]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_Infusions', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_Infusions] (
            [InfusionEventKey] NVARCHAR(250) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NOT NULL,
            [PrescriptionID] NVARCHAR(100) NULL,
            [BottleID] NVARCHAR(100) NULL,
            [EventKind] VARCHAR(40) NOT NULL,
            [ScheduleDateTime] DATETIME2(0) NULL,
            [AdministrationStartDateTime] DATETIME2(0) NULL,
            [MedicationTradeName] NVARCHAR(300) NULL,
            [MedicationGenericName] NVARCHAR(300) NULL,
            [Administration] NVARCHAR(200) NULL,
            [Dose] DECIMAL(18,4) NULL,
            [DoseUnits] NVARCHAR(60) NULL,
            [Rate] DECIMAL(18,4) NULL,
            [RateUnits] NVARCHAR(60) NULL,
            [Volume] DECIMAL(18,4) NULL,
            [InfusionType] NVARCHAR(100) NULL,
            [InfusionStatus] NVARCHAR(100) NULL,
            [TotalIntake] DECIMAL(18,4) NULL,
            [ElapsedTime] DECIMAL(18,4) NULL,
            [TotalDose] DECIMAL(18,4) NULL,
            [BolusDescription] NVARCHAR(500) NULL,
            [DocumentedByUserID] NVARCHAR(100) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Infusions') AND name = N'UX_Infusions_Key')
        CREATE UNIQUE INDEX [UX_Infusions_Key] ON dbo.[tbl_FCAP1A_Infusions] ([InfusionEventKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Infusions') AND name = N'IX_Infusions_PatientTime')
            CREATE INDEX [IX_Infusions_PatientTime] ON dbo.[tbl_FCAP1A_Infusions] ([PatientID], [AdministrationStartDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [InfusionEventKey] NVARCHAR(250) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NOT NULL,
            [PrescriptionID] NVARCHAR(100) NULL,
            [BottleID] NVARCHAR(100) NULL,
            [EventKind] VARCHAR(40) NOT NULL,
            [ScheduleDateTime] DATETIME2(0) NULL,
            [AdministrationStartDateTime] DATETIME2(0) NULL,
            [MedicationTradeName] NVARCHAR(300) NULL,
            [MedicationGenericName] NVARCHAR(300) NULL,
            [Administration] NVARCHAR(200) NULL,
            [Dose] DECIMAL(18,4) NULL,
            [DoseUnits] NVARCHAR(60) NULL,
            [Rate] DECIMAL(18,4) NULL,
            [RateUnits] NVARCHAR(60) NULL,
            [Volume] DECIMAL(18,4) NULL,
            [InfusionType] NVARCHAR(100) NULL,
            [InfusionStatus] NVARCHAR(100) NULL,
            [TotalIntake] DECIMAL(18,4) NULL,
            [ElapsedTime] DECIMAL(18,4) NULL,
            [TotalDose] DECIMAL(18,4) NULL,
            [BolusDescription] NVARCHAR(500) NULL,
            [DocumentedByUserID] NVARCHAR(100) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH InfusionEvents AS (
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
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarLastDocumented d
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main r ON r.SourceID = d.SourceID AND r.VisitID = d.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarMeds m ON m.SourceID = d.SourceID AND m.VisitID = d.VisitID
                AND m.MedicationPrescriptionNumberID = d.MarLastDocumentedPrescriptionID AND m.MarBottleNumberID = d.MarLastDocumentedBottleID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarRxs rx ON rx.SourceID=d.SourceID AND rx.VisitID=d.VisitID
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
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarLastTitration t
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main r ON r.SourceID = t.SourceID AND r.VisitID = t.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarMeds m ON m.SourceID = t.SourceID AND m.VisitID = t.VisitID
                AND m.MedicationPrescriptionNumberID = t.MarLastTitrationPrescriptionID AND m.MarBottleNumberID = t.MarLastTitrationBottleID
            WHERE t.MarLastTitrationDateTime >= @WindowStart AND t.MarLastTitrationDateTime < DATEADD(DAY, 1, @WindowEnd)

            UNION ALL
            SELECT CONVERT(NVARCHAR(250), CONCAT('BAG|', b.SourceID, '|', b.VisitID, '|', b.BagPrescriptionID, '|', b.BagBottleID, '|', b.BagMarActivityUrnID)),
                   b.SourceID, r.PatientID, b.VisitID, b.BagPrescriptionID, b.BagBottleID, CONVERT(VARCHAR(40), 'bag-last-documented'),
                   b.BagScheduleDateTimeID, b.BagLastDocumentedDateTime, m.MedicationTradeName, m.MedicationGenericName, NULL,
                   NULL, NULL, TRY_CONVERT(DECIMAL(18,4), b.BagLastDocumentedInfusionRate), b.BagPrescriptionRateUnits,
                   TRY_CONVERT(DECIMAL(18,4), b.BagLastDocumentedInfusionVolume), NULL, NULL, NULL, NULL, NULL, NULL,
                   b.BagLastDocumentedUser_UnvUserID, CONVERT(SYSNAME, 'PcsMarAct_BagInfusionLastDoc'), b.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_BagInfusionLastDoc b
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main r ON r.SourceID = b.SourceID AND r.VisitID = b.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarMeds m ON m.SourceID = b.SourceID AND m.VisitID = b.VisitID
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
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarActivityTitr t
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main r ON r.SourceID=t.SourceID AND r.VisitID=t.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarMeds m ON m.SourceID=t.SourceID AND m.VisitID=t.VisitID
                AND m.MedicationPrescriptionNumberID=t.MarActivityPrescriptionTitrationID AND m.MarBottleNumberID=t.MarActivityBottleTitrationID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].PcsMarAct_MarRxs rx ON rx.SourceID=t.SourceID AND rx.VisitID=t.VisitID
                AND rx.MedicationPrescriptionNumberID=t.MarActivityPrescriptionTitrationID AND rx.MarBottleNumberID=t.MarActivityBottleTitrationID
            WHERE COALESCE(t.MarActivityTitrationDocumentationDateTime,t.MarActivityTitrationRecordDateTime) >= @WindowStart
              AND COALESCE(t.MarActivityTitrationDocumentationDateTime,t.MarActivityTitrationRecordDateTime) < DATEADD(DAY,1,@WindowEnd)
        ), Ranked AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY InfusionEventKey ORDER BY RowUpdateDateTime DESC) AS rn FROM InfusionEvents
        )
        INSERT #Build ([InfusionEventKey], [SourceID], [PatientID], [VisitID], [PrescriptionID], [BottleID], [EventKind], [ScheduleDateTime], [AdministrationStartDateTime], [MedicationTradeName], [MedicationGenericName], [Administration], [Dose], [DoseUnits], [Rate], [RateUnits], [Volume], [InfusionType], [InfusionStatus], [TotalIntake], [ElapsedTime], [TotalDose], [BolusDescription], [DocumentedByUserID], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
        SELECT InfusionEventKey, SourceID, CONVERT(NVARCHAR(50), PatientID), CONVERT(NVARCHAR(50), VisitID),
               CONVERT(NVARCHAR(100), PrescriptionID), CONVERT(NVARCHAR(100), BottleID), EventKind,
               CONVERT(DATETIME2(0), ScheduleDateTime), CONVERT(DATETIME2(0), AdministrationStartDateTime),
               CONVERT(NVARCHAR(300), MedicationTradeName), CONVERT(NVARCHAR(300), MedicationGenericName),
               CONVERT(NVARCHAR(200), Administration), Dose, CONVERT(NVARCHAR(60), DoseUnits), Rate,
               CONVERT(NVARCHAR(60), RateUnits), Volume, CONVERT(NVARCHAR(100), InfusionType),
               CONVERT(NVARCHAR(100), InfusionStatus), TotalIntake, ElapsedTime, TotalDose,
               CONVERT(NVARCHAR(500), BolusDescription), CONVERT(NVARCHAR(100), DocumentedByUserID),
               SourceTable, CONVERT(DATETIME2(0), RowUpdateDateTime), CONVERT(DATETIME2(0), SYSDATETIME())
        FROM Ranked WHERE rn = 1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_Infusions];
            INSERT INTO dbo.[tbl_FCAP1A_Infusions] ([InfusionEventKey], [SourceID], [PatientID], [VisitID], [PrescriptionID], [BottleID], [EventKind], [ScheduleDateTime], [AdministrationStartDateTime], [MedicationTradeName], [MedicationGenericName], [Administration], [Dose], [DoseUnits], [Rate], [RateUnits], [Volume], [InfusionType], [InfusionStatus], [TotalIntake], [ElapsedTime], [TotalDose], [BolusDescription], [DocumentedByUserID], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
            SELECT [InfusionEventKey], [SourceID], [PatientID], [VisitID], [PrescriptionID], [BottleID], [EventKind], [ScheduleDateTime], [AdministrationStartDateTime], [MedicationTradeName], [MedicationGenericName], [Administration], [Dose], [DoseUnits], [Rate], [RateUnits], [Volume], [InfusionType], [InfusionStatus], [TotalIntake], [ElapsedTime], [TotalDose], [BolusDescription], [DocumentedByUserID], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Infusions',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Infusions',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
