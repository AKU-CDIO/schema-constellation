USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_Registries
    Purpose   : Builds registry membership and longitudinal registry laboratory observations.
    Grain     : one row per registry membership or observation
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_Registries]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_Registries', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_Registries] (
            [RegistryEventKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [RegistryEventType] VARCHAR(30) NOT NULL,
            [ObservationCode] NVARCHAR(160) NULL,
            [ObservationValue] NVARCHAR(2000) NULL,
            [EnrollmentDateTime] DATETIME2(0) NULL,
            [ObservationDateTime] DATETIME2(0) NULL,
            [Active] BIT NULL,
            [AbnormalFlags] NVARCHAR(100) NULL,
            [CarePlan] NVARCHAR(2000) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Registries') AND name = N'UX_Registries_Key')
        CREATE UNIQUE INDEX [UX_Registries_Key] ON dbo.[tbl_FCAP1A_Registries] ([RegistryEventKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Registries') AND name = N'IX_Registries_PatientTime')
            CREATE INDEX [IX_Registries_PatientTime] ON dbo.[tbl_FCAP1A_Registries] ([PatientID], [EnrollmentDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [RegistryEventKey] NVARCHAR(220) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [RegistryEventType] VARCHAR(30) NOT NULL,
            [ObservationCode] NVARCHAR(160) NULL,
            [ObservationValue] NVARCHAR(2000) NULL,
            [EnrollmentDateTime] DATETIME2(0) NULL,
            [ObservationDateTime] DATETIME2(0) NULL,
            [Active] BIT NULL,
            [AbnormalFlags] NVARCHAR(100) NULL,
            [CarePlan] NVARCHAR(2000) NULL,
            [SourceTable] SYSNAME NOT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        ;WITH RegistryEvents AS(
            SELECT CONVERT(NVARCHAR(220),CONCAT('MEMBER|',r.SourceID,'|',r.PatientID))RegistryEventKey,r.SourceID,r.PatientID,
                   CONVERT(VARCHAR(30),'membership')RegistryEventType,CONVERT(NVARCHAR(160),NULL)ObservationCode,
                   CONVERT(NVARCHAR(2000),r.Problems)ObservationValue,r.RowUpdateDateTime EnrollmentDateTime,CONVERT(DATETIME2(0),NULL)ObservationDateTime,
                   CONVERT(BIT,CASE WHEN r.Active IN('Y','YES','1')THEN 1 WHEN r.Active IN('N','NO','0')THEN 0 END)Active,
                   CONVERT(NVARCHAR(100),NULL)AbnormalFlags,CONVERT(NVARCHAR(2000),r.CarePlan)CarePlan,CONVERT(SYSNAME,'EmrPatRegistry_Main')SourceTable,r.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPatRegistry_Main r INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('LAB|',r.SourceID,'|',r.PatientID,'|',r.LaboratoryTestID,'|',CONVERT(VARCHAR(33),r.LaboratoryDateTime,126))),
                   r.SourceID,r.PatientID,'laboratory',r.LaboratoryTestID,CONVERT(NVARCHAR(2000),r.LaboratoryValue),NULL,r.LaboratoryDateTime,NULL,
                   r.LaboratoryAbnormalFlags,NULL,'EmrPatRegistry_LastLabResults',r.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPatRegistry_LastLabResults r INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
            WHERE COALESCE(r.LaboratoryDateTime,r.RowUpdateDateTime)>=@WindowStart AND COALESCE(r.LaboratoryDateTime,r.RowUpdateDateTime)<DATEADD(DAY,1,@WindowEnd)
            UNION ALL
            SELECT CONVERT(NVARCHAR(220),CONCAT('CHRONIC|',r.SourceID,'|',r.PatientID)),r.SourceID,r.PatientID,'chronic-condition-index',
                   NULL,NULL,r.RowUpdateDateTime,NULL,NULL,NULL,NULL,'EmrPatRegistry_ChronicConds',r.RowUpdateDateTime
            FROM [NBIDRSRV2].[AKULiveATdb].[dbo].EmrPatRegistry_ChronicConds r INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=r.PatientID
        ),Ranked AS(SELECT *,ROW_NUMBER()OVER(PARTITION BY RegistryEventKey ORDER BY RowUpdateDateTime DESC)rn FROM RegistryEvents)
        INSERT #Build ([RegistryEventKey], [SourceID], [PatientID], [RegistryEventType], [ObservationCode], [ObservationValue], [EnrollmentDateTime], [ObservationDateTime], [Active], [AbnormalFlags], [CarePlan], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
        SELECT RegistryEventKey,SourceID,CONVERT(NVARCHAR(50),PatientID),RegistryEventType,CONVERT(NVARCHAR(160),ObservationCode),
               CONVERT(NVARCHAR(2000),ObservationValue),CONVERT(DATETIME2(0),EnrollmentDateTime),CONVERT(DATETIME2(0),ObservationDateTime),
               Active,CONVERT(NVARCHAR(100),AbnormalFlags),CONVERT(NVARCHAR(2000),CarePlan),SourceTable,
               CONVERT(DATETIME2(0),RowUpdateDateTime),SYSDATETIME()FROM Ranked WHERE rn=1;

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_Registries];
            INSERT INTO dbo.[tbl_FCAP1A_Registries] ([RegistryEventKey], [SourceID], [PatientID], [RegistryEventType], [ObservationCode], [ObservationValue], [EnrollmentDateTime], [ObservationDateTime], [Active], [AbnormalFlags], [CarePlan], [SourceTable], [RowUpdateDateTime], [ExtractedOn])
            SELECT [RegistryEventKey], [SourceID], [PatientID], [RegistryEventType], [ObservationCode], [ObservationValue], [EnrollmentDateTime], [ObservationDateTime], [Active], [AbnormalFlags], [CarePlan], [SourceTable], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Registries & Analytics',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Registries & Analytics',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
