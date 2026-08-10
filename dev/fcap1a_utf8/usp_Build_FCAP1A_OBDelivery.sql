USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_OBDelivery
    Purpose   : Builds pregnancy episodes and visit linkage; explicitly distinguishes estimated delivery from unavailable structured actual-delivery time.
    Grain     : one row per pregnancy episode
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_OBDelivery]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_OBDelivery', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_OBDelivery] (
            [PregnancyKey] NVARCHAR(180) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [PregnancyCountID] INT NOT NULL,
            [PregnancyActive] BIT NULL,
            [PregnancyStatus] NVARCHAR(100) NULL,
            [LastMenstrualPeriod] DATE NULL,
            [ConceptionDate] DATE NULL,
            [UltrasoundDate] DATE NULL,
            [EstimatedDeliveryDate] DATE NULL,
            [DeliveryDateTime] DATETIME2(0) NULL,
            [FetalCount] INT NULL,
            [InitialWeight] DECIMAL(18,4) NULL,
            [InitialWeightUnit] NVARCHAR(40) NULL,
            [CompletedByUserID] NVARCHAR(100) NULL,
            [CompletedDateTime] DATETIME2(0) NULL,
            [ActualDeliveryCaptured] BIT NOT NULL,
            [CoverageNote] NVARCHAR(500) NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_OBDelivery') AND name = N'UX_OBDelivery_Key')
        CREATE UNIQUE INDEX [UX_OBDelivery_Key] ON dbo.[tbl_FCAP1A_OBDelivery] ([PregnancyKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_OBDelivery') AND name = N'IX_OBDelivery_PatientTime')
            CREATE INDEX [IX_OBDelivery_PatientTime] ON dbo.[tbl_FCAP1A_OBDelivery] ([PatientID], [DeliveryDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [PregnancyKey] NVARCHAR(180) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [PregnancyCountID] INT NOT NULL,
            [PregnancyActive] BIT NULL,
            [PregnancyStatus] NVARCHAR(100) NULL,
            [LastMenstrualPeriod] DATE NULL,
            [ConceptionDate] DATE NULL,
            [UltrasoundDate] DATE NULL,
            [EstimatedDeliveryDate] DATE NULL,
            [DeliveryDateTime] DATETIME2(0) NULL,
            [FetalCount] INT NULL,
            [InitialWeight] DECIMAL(18,4) NULL,
            [InitialWeightUnit] NVARCHAR(40) NULL,
            [CompletedByUserID] NVARCHAR(100) NULL,
            [CompletedDateTime] DATETIME2(0) NULL,
            [ActualDeliveryCaptured] BIT NOT NULL,
            [CoverageNote] NVARCHAR(500) NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        INSERT #Build ([PregnancyKey], [SourceID], [PatientID], [VisitID], [PregnancyCountID], [PregnancyActive], [PregnancyStatus], [LastMenstrualPeriod], [ConceptionDate], [UltrasoundDate], [EstimatedDeliveryDate], [DeliveryDateTime], [FetalCount], [InitialWeight], [InitialWeightUnit], [CompletedByUserID], [CompletedDateTime], [ActualDeliveryCaptured], [CoverageNote], [RowUpdateDateTime], [ExtractedOn])
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
        FROM [NBIDRSRV2].[AKULiveATdb].[dbo].AmbPatCm_PregnancyData p LEFT JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].AmbPatCm_PregnancyMain pm ON pm.SourceID=p.SourceID AND pm.PatientID=p.PatientID INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=p.PatientID
        OUTER APPLY(SELECT TOP(1) x.PregnancyVisit_RegAcctID FROM [NBIDRSRV2].[AKULiveATdb].[dbo].AmbPatCm_PregnancyVisitLog x
                    WHERE x.SourceID=p.SourceID AND x.PatientID=p.PatientID AND x.PregnancyCountID=p.PregnancyCountID
                    ORDER BY x.RowUpdateDateTime DESC,x.PregnancyVisitUrnID DESC)v
        WHERE COALESCE(p.CompletedByDateTime,p.ConceptionDate,p.LastMenstrualPeriod,p.EstimatedDeliveryDate,p.RowUpdateDateTime) < DATEADD(DAY,1,@WindowEnd);

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_OBDelivery];
            INSERT INTO dbo.[tbl_FCAP1A_OBDelivery] ([PregnancyKey], [SourceID], [PatientID], [VisitID], [PregnancyCountID], [PregnancyActive], [PregnancyStatus], [LastMenstrualPeriod], [ConceptionDate], [UltrasoundDate], [EstimatedDeliveryDate], [DeliveryDateTime], [FetalCount], [InitialWeight], [InitialWeightUnit], [CompletedByUserID], [CompletedDateTime], [ActualDeliveryCaptured], [CoverageNote], [RowUpdateDateTime], [ExtractedOn])
            SELECT [PregnancyKey], [SourceID], [PatientID], [VisitID], [PregnancyCountID], [PregnancyActive], [PregnancyStatus], [LastMenstrualPeriod], [ConceptionDate], [UltrasoundDate], [EstimatedDeliveryDate], [DeliveryDateTime], [FetalCount], [InitialWeight], [InitialWeightUnit], [CompletedByUserID], [CompletedDateTime], [ActualDeliveryCaptured], [CoverageNote], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'OB / Delivery',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'OB / Delivery',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
