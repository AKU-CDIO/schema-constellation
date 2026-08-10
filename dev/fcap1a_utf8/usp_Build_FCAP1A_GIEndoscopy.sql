USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_GIEndoscopy
    Purpose   : Builds cohort-scoped GI - Endoscopy evidence from audited orders and report metadata.
    Grain     : one row per endoscopy order/report evidence
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_GIEndoscopy]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_GIEndoscopy', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_GIEndoscopy] (
            [EventKey] NVARCHAR(250) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [SourceRecordID] NVARCHAR(100) NULL,
            [TopicCode] VARCHAR(30) NOT NULL,
            [SourceKind] VARCHAR(30) NOT NULL,
            [ClinicalName] NVARCHAR(300) NULL,
            [EventDateTime] DATETIME2(0) NULL,
            [OrderDateTime] DATETIME2(0) NULL,
            [ResultDateTime] DATETIME2(0) NULL,
            [Status] NVARCHAR(100) NULL,
            [Priority] NVARCHAR(60) NULL,
            [ProviderID] NVARCHAR(100) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [LocationID] NVARCHAR(60) NULL,
            [OrderNumber] NVARCHAR(100) NULL,
            [ResultIdentifier] NVARCHAR(200) NULL,
            [InterpretationType] NVARCHAR(100) NULL,
            [ResultReference] NVARCHAR(1000) NULL,
            [AssetAvailable] BIT NOT NULL,
            [ExternalAssetRequired] BIT NOT NULL,
            [EvidenceTier] VARCHAR(40) NOT NULL,
            [CoverageNote] NVARCHAR(500) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_GIEndoscopy') AND name = N'UX_GIEndoscopy_Key')
        CREATE UNIQUE INDEX [UX_GIEndoscopy_Key] ON dbo.[tbl_FCAP1A_GIEndoscopy] ([EventKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_GIEndoscopy') AND name = N'IX_GIEndoscopy_PatientTime')
            CREATE INDEX [IX_GIEndoscopy_PatientTime] ON dbo.[tbl_FCAP1A_GIEndoscopy] ([PatientID], [EventDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [EventKey] NVARCHAR(250) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [SourceRecordID] NVARCHAR(100) NULL,
            [TopicCode] VARCHAR(30) NOT NULL,
            [SourceKind] VARCHAR(30) NOT NULL,
            [ClinicalName] NVARCHAR(300) NULL,
            [EventDateTime] DATETIME2(0) NULL,
            [OrderDateTime] DATETIME2(0) NULL,
            [ResultDateTime] DATETIME2(0) NULL,
            [Status] NVARCHAR(100) NULL,
            [Priority] NVARCHAR(60) NULL,
            [ProviderID] NVARCHAR(100) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [LocationID] NVARCHAR(60) NULL,
            [OrderNumber] NVARCHAR(100) NULL,
            [ResultIdentifier] NVARCHAR(200) NULL,
            [InterpretationType] NVARCHAR(100) NULL,
            [ResultReference] NVARCHAR(1000) NULL,
            [AssetAvailable] BIT NOT NULL,
            [ExternalAssetRequired] BIT NOT NULL,
            [EvidenceTier] VARCHAR(40) NOT NULL,
            [CoverageNote] NVARCHAR(500) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH Evidence AS (
            SELECT
                CONVERT(NVARCHAR(250), CONCAT('ORDER|', o.SourceID, '|', o.OmOrdID)) AS EventKey,
                o.SourceID, CONVERT(NVARCHAR(50), o.PatientID) AS PatientID,
                CONVERT(NVARCHAR(50), o.VisitID) AS VisitID, CONVERT(NVARCHAR(100), o.OmOrdID) AS SourceRecordID,
                CONVERT(VARCHAR(30), 'gi') AS TopicCode, CONVERT(VARCHAR(30), 'order') AS SourceKind,
                CONVERT(NVARCHAR(300), COALESCE(d.Name, d.Mnemonic, o2.Alias, o.OrderType)) AS ClinicalName,
                CONVERT(DATETIME2(0), COALESCE(o3.LastEventDateTime, o3.StartDateTime, o.OrderDateTime)) AS EventDateTime,
                CONVERT(DATETIME2(0), o.OrderDateTime) AS OrderDateTime, CONVERT(DATETIME2(0), o3.LastEventDateTime) AS ResultDateTime,
                CONVERT(NVARCHAR(100), o3.Status) AS Status, CONVERT(NVARCHAR(60), o2.Priority) AS Priority,
                CONVERT(NVARCHAR(100), COALESCE(o2.OrderProvider, o3.RequestProvider, o.OrderUser_UnvUserID)) AS ProviderID,
                CONVERT(NVARCHAR(60), o.Facility_MisFacID) AS FacilityID,
                CONVERT(NVARCHAR(60), COALESCE(o3.OrderLocation_MisLocID, o2.RequisitionLocation_MisLocID)) AS LocationID,
                CONVERT(NVARCHAR(100), o.OrderNumber) AS OrderNumber, CONVERT(NVARCHAR(200), d.Mnemonic) AS ResultIdentifier,
                CONVERT(NVARCHAR(100), NULL) AS InterpretationType, CONVERT(NVARCHAR(1000), NULL) AS ResultReference,
                CONVERT(BIT, 0) AS AssetAvailable, CONVERT(BIT, 0) AS ExternalAssetRequired,
                CONVERT(VARCHAR(40), 'relational-order') AS EvidenceTier,
                CONVERT(NVARCHAR(500), N'Relational order/report evidence only; validate the owning system before treating it as a structured measurement set.') AS CoverageNote,
                CONVERT(SYSNAME, 'OmOrd_Main') AS SourceTable,
                CONVERT(DATETIME2(0), COALESCE(o3.RowUpdateDateTime, o2.RowUpdateDateTime, o.RowUpdateDateTime)) AS RowUpdateDateTime,
                CONVERT(DATETIME2(0), SYSDATETIME()) AS ExtractedOn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main o
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = o.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main2 o2 ON o2.SourceID = o.SourceID AND o2.OmOrdID = o.OmOrdID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main3 o3 ON o3.SourceID = o.SourceID AND o3.OmOrdID = o.OmOrdID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrdDict_Main d ON d.SourceID = o.SourceID AND d.OmOrdDictID = o2.Procedure_OmOrdDictID
            WHERE o.OrderDateTime >= @WindowStart AND o.OrderDateTime < DATEADD(DAY, 1, @WindowEnd)
              AND (UPPER(CONCAT_WS(' ', d.Mnemonic, d.Name, d.CategoryName, d.Type, o.OrderType, o2.Alias)) LIKE '%ENDOSCOPY%' OR
                UPPER(CONCAT_WS(' ', d.Mnemonic, d.Name, d.CategoryName, d.Type, o.OrderType, o2.Alias)) LIKE '%COLONOSCOPY%' OR
                UPPER(CONCAT_WS(' ', d.Mnemonic, d.Name, d.CategoryName, d.Type, o.OrderType, o2.Alias)) LIKE '%GASTROSCOPY%' OR
                UPPER(CONCAT_WS(' ', d.Mnemonic, d.Name, d.CategoryName, d.Type, o.OrderType, o2.Alias)) LIKE '%SIGMOIDOSCOPY%')

            UNION ALL

            SELECT
                CONVERT(NVARCHAR(250), CONCAT('REPORT|', i.SourceID, '|', i.VisitID, '|', i.DataUrnID, '|', i.ImageKeyID)),
                i.SourceID, CONVERT(NVARCHAR(50), r.PatientID), CONVERT(NVARCHAR(50), i.VisitID),
                CONVERT(NVARCHAR(100), CONCAT_WS('|', i.DataUrnID, i.ImageKeyID)), CONVERT(VARCHAR(30), 'gi'),
                CONVERT(VARCHAR(30), 'report'), CONVERT(NVARCHAR(300), COALESCE(i.ImageInterpretationType, i.Vendor, i.ImageIdentifier)),
                CONVERT(DATETIME2(0), COALESCE(i.ImageDate, i.RowUpdateDateTime)), NULL,
                CONVERT(DATETIME2(0), COALESCE(i.ImageDate, i.RowUpdateDateTime)), CONVERT(NVARCHAR(100), i.ImageStatus), NULL, NULL,
                NULL, NULL, NULL, CONVERT(NVARCHAR(200), i.ImageIdentifier), CONVERT(NVARCHAR(100), i.ImageInterpretationType),
                CONVERT(NVARCHAR(1000), i.ImageUrl), CONVERT(BIT, IIF(NULLIF(LTRIM(RTRIM(i.ImageUrl)), '') IS NULL, 0, 1)),
                CONVERT(BIT, 0), CONVERT(VARCHAR(40), 'relational-report'),
                CONVERT(NVARCHAR(500), N'Relational order/report evidence only; validate the owning system before treating it as a structured measurement set.'), CONVERT(SYSNAME, 'EmrAcctRep_Images'),
                CONVERT(DATETIME2(0), i.RowUpdateDateTime), CONVERT(DATETIME2(0), SYSDATETIME())
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrAcctRep_Images i
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].RegAcct_Main r ON r.SourceID = i.SourceID AND r.VisitID = i.VisitID
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = r.PatientID
            WHERE COALESCE(i.ImageDate, i.RowUpdateDateTime) >= @WindowStart
              AND COALESCE(i.ImageDate, i.RowUpdateDateTime) < DATEADD(DAY, 1, @WindowEnd)
              AND (UPPER(CONCAT_WS(' ', i.Vendor, i.ImageIdentifier, i.ImageStatus, i.ImageInterpretationType, i.ImageUrl)) LIKE '%ENDOSCOPY%' OR
                UPPER(CONCAT_WS(' ', i.Vendor, i.ImageIdentifier, i.ImageStatus, i.ImageInterpretationType, i.ImageUrl)) LIKE '%COLONOSCOPY%' OR
                UPPER(CONCAT_WS(' ', i.Vendor, i.ImageIdentifier, i.ImageStatus, i.ImageInterpretationType, i.ImageUrl)) LIKE '%GASTROSCOPY%' OR
                UPPER(CONCAT_WS(' ', i.Vendor, i.ImageIdentifier, i.ImageStatus, i.ImageInterpretationType, i.ImageUrl)) LIKE '%SIGMOIDOSCOPY%')
        ), Ranked AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY EventKey ORDER BY RowUpdateDateTime DESC, SourceKind) AS rn
            FROM Evidence
        )
        INSERT #Build ([EventKey], [SourceID], [PatientID], [VisitID], [SourceRecordID], [TopicCode], [SourceKind], [ClinicalName], [EventDateTime], [OrderDateTime], [ResultDateTime], [Status], [Priority], [ProviderID], [FacilityID], [LocationID], [OrderNumber], [ResultIdentifier], [InterpretationType], [ResultReference], [AssetAvailable], [ExternalAssetRequired], [EvidenceTier], [CoverageNote], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
        SELECT [EventKey], [SourceID], [PatientID], [VisitID], [SourceRecordID], [TopicCode], [SourceKind], [ClinicalName], [EventDateTime], [OrderDateTime], [ResultDateTime], [Status], [Priority], [ProviderID], [FacilityID], [LocationID], [OrderNumber], [ResultIdentifier], [InterpretationType], [ResultReference], [AssetAvailable], [ExternalAssetRequired], [EvidenceTier], [CoverageNote], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM Ranked WHERE rn = 1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_GIEndoscopy];
            INSERT INTO dbo.[tbl_FCAP1A_GIEndoscopy] ([EventKey], [SourceID], [PatientID], [VisitID], [SourceRecordID], [TopicCode], [SourceKind], [ClinicalName], [EventDateTime], [OrderDateTime], [ResultDateTime], [Status], [Priority], [ProviderID], [FacilityID], [LocationID], [OrderNumber], [ResultIdentifier], [InterpretationType], [ResultReference], [AssetAvailable], [ExternalAssetRequired], [EvidenceTier], [CoverageNote], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
            SELECT [EventKey], [SourceID], [PatientID], [VisitID], [SourceRecordID], [TopicCode], [SourceKind], [ClinicalName], [EventDateTime], [OrderDateTime], [ResultDateTime], [Status], [Priority], [ProviderID], [FacilityID], [LocationID], [OrderNumber], [ResultIdentifier], [InterpretationType], [ResultReference], [AssetAvailable], [ExternalAssetRequired], [EvidenceTier], [CoverageNote], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'GI - Endoscopy',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'GI - Endoscopy',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
