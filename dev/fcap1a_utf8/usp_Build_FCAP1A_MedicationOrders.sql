USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_MedicationOrders
    Purpose   : Builds a dedicated cohort-scoped order contract with dictionary and lifecycle context.
    Grain     : one row per order
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_MedicationOrders]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_MedicationOrders', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_MedicationOrders] (
            [OrderKey] NVARCHAR(160) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [OrderID] NVARCHAR(80) NOT NULL,
            [OrderNumber] NVARCHAR(100) NULL,
            [OrderDateTime] DATETIME2(0) NULL,
            [StartDateTime] DATETIME2(0) NULL,
            [LastEventDateTime] DATETIME2(0) NULL,
            [Status] NVARCHAR(100) NULL,
            [OrderType] NVARCHAR(100) NULL,
            [ProcedureID] NVARCHAR(80) NULL,
            [Mnemonic] NVARCHAR(100) NULL,
            [OrderName] NVARCHAR(300) NULL,
            [CategoryID] NVARCHAR(80) NULL,
            [CategoryName] NVARCHAR(200) NULL,
            [Priority] NVARCHAR(60) NULL,
            [Quantity] DECIMAL(18,4) NULL,
            [OrderingProviderID] NVARCHAR(100) NULL,
            [RequestingProviderID] NVARCHAR(100) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [LocationID] NVARCHAR(60) NULL,
            [OrderOrigin] NVARCHAR(100) NULL,
            [MedicationIndicator] BIT NOT NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_MedicationOrders') AND name = N'UX_MedicationOrders_Key')
        CREATE UNIQUE INDEX [UX_MedicationOrders_Key] ON dbo.[tbl_FCAP1A_MedicationOrders] ([OrderKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_MedicationOrders') AND name = N'IX_MedicationOrders_PatientTime')
            CREATE INDEX [IX_MedicationOrders_PatientTime] ON dbo.[tbl_FCAP1A_MedicationOrders] ([PatientID], [OrderDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [OrderKey] NVARCHAR(160) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [OrderID] NVARCHAR(80) NOT NULL,
            [OrderNumber] NVARCHAR(100) NULL,
            [OrderDateTime] DATETIME2(0) NULL,
            [StartDateTime] DATETIME2(0) NULL,
            [LastEventDateTime] DATETIME2(0) NULL,
            [Status] NVARCHAR(100) NULL,
            [OrderType] NVARCHAR(100) NULL,
            [ProcedureID] NVARCHAR(80) NULL,
            [Mnemonic] NVARCHAR(100) NULL,
            [OrderName] NVARCHAR(300) NULL,
            [CategoryID] NVARCHAR(80) NULL,
            [CategoryName] NVARCHAR(200) NULL,
            [Priority] NVARCHAR(60) NULL,
            [Quantity] DECIMAL(18,4) NULL,
            [OrderingProviderID] NVARCHAR(100) NULL,
            [RequestingProviderID] NVARCHAR(100) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [LocationID] NVARCHAR(60) NULL,
            [OrderOrigin] NVARCHAR(100) NULL,
            [MedicationIndicator] BIT NOT NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH Ranked AS (
            SELECT o.*, o2.Procedure_OmOrdDictID, o2.Priority, o2.Quantity, o2.OrderProvider,
                   o2.RequisitionLocation_MisLocID, o3.StartDateTime, o3.LastEventDateTime,
                   o3.Status, o3.RequestProvider, o3.OrderLocation_MisLocID,
                   d.Mnemonic, d.Name AS OrderName, d.CategoryName, d.Type AS DictionaryType,
                   d.AmbulatoryMedication, CONVERT(BIT, IIF((NULLIF(o.AomMedicationType, '') IS NOT NULL OR d.AmbulatoryMedication IN ('Y','YES') OR d.Type LIKE '%MED%'), 1, 0)) AS MedicationIndicator,
                   ROW_NUMBER() OVER (PARTITION BY o.SourceID, o.OmOrdID
                                      ORDER BY COALESCE(o3.RowUpdateDateTime, o2.RowUpdateDateTime, o.RowUpdateDateTime) DESC) AS rn
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main o
            INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = o.PatientID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main2 o2 ON o2.SourceID = o.SourceID AND o2.OmOrdID = o.OmOrdID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrd_Main3 o3 ON o3.SourceID = o.SourceID AND o3.OmOrdID = o.OmOrdID
            LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].OmOrdDict_Main d ON d.SourceID = o.SourceID AND d.OmOrdDictID = o2.Procedure_OmOrdDictID
            WHERE o.OrderDateTime >= @WindowStart AND o.OrderDateTime < DATEADD(DAY, 1, @WindowEnd)
              AND (NULLIF(o.AomMedicationType, '') IS NOT NULL OR d.AmbulatoryMedication IN ('Y','YES') OR d.Type LIKE '%MED%')
        )
        INSERT #Build ([OrderKey], [SourceID], [PatientID], [VisitID], [OrderID], [OrderNumber], [OrderDateTime], [StartDateTime], [LastEventDateTime], [Status], [OrderType], [ProcedureID], [Mnemonic], [OrderName], [CategoryID], [CategoryName], [Priority], [Quantity], [OrderingProviderID], [RequestingProviderID], [FacilityID], [LocationID], [OrderOrigin], [MedicationIndicator], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
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
        FROM Ranked WHERE rn = 1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_MedicationOrders];
            INSERT INTO dbo.[tbl_FCAP1A_MedicationOrders] ([OrderKey], [SourceID], [PatientID], [VisitID], [OrderID], [OrderNumber], [OrderDateTime], [StartDateTime], [LastEventDateTime], [Status], [OrderType], [ProcedureID], [Mnemonic], [OrderName], [CategoryID], [CategoryName], [Priority], [Quantity], [OrderingProviderID], [RequestingProviderID], [FacilityID], [LocationID], [OrderOrigin], [MedicationIndicator], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
            SELECT [OrderKey], [SourceID], [PatientID], [VisitID], [OrderID], [OrderNumber], [OrderDateTime], [StartDateTime], [LastEventDateTime], [Status], [OrderType], [ProcedureID], [Mnemonic], [OrderName], [CategoryID], [CategoryName], [Priority], [Quantity], [OrderingProviderID], [RequestingProviderID], [FacilityID], [LocationID], [OrderOrigin], [MedicationIndicator], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Medication Orders',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Medication Orders',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
