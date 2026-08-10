USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_Surgical_Cases_Extended
    Purpose   : Builds surgical case headers enriched with appointment, primary actual procedure, operative times, and implant counts.
    Grain     : one row per surgical case
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_Surgical_Cases_Extended]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_Surgical_Cases_Extended', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_Surgical_Cases_Extended] (
            [SurgicalCaseKey] NVARCHAR(160) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [SurgicalCaseID] NVARCHAR(80) NOT NULL,
            [SurgeryStartDateTime] DATETIME2(0) NULL,
            [ScheduledDateTime] DATETIME2(0) NULL,
            [ArrivalDateTime] DATETIME2(0) NULL,
            [OperatingRoomID] NVARCHAR(80) NULL,
            [SurgicalAreaID] NVARCHAR(80) NULL,
            [CaseTypeID] NVARCHAR(80) NULL,
            [SurgeonID] NVARCHAR(100) NULL,
            [AnesthesiologistID] NVARCHAR(100) NULL,
            [AnesthesiaTypeID] NVARCHAR(80) NULL,
            [TotalDurationMinutes] INT NULL,
            [ProcedureID] NVARCHAR(100) NULL,
            [ProcedureDescription] NVARCHAR(1000) NULL,
            [ProcedureStartDateTime] DATETIME2(0) NULL,
            [ProcedureEndDateTime] DATETIME2(0) NULL,
            [ProcedureSide] NVARCHAR(60) NULL,
            [WoundClass] NVARCHAR(100) NULL,
            [ImplantCount] INT NOT NULL,
            [SchedulerNotes] NVARCHAR(2000) NULL,
            [Delayed] BIT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Surgical_Cases_Extended') AND name = N'UX_SurgicalCasesExtended_Key')
        CREATE UNIQUE INDEX [UX_SurgicalCasesExtended_Key] ON dbo.[tbl_FCAP1A_Surgical_Cases_Extended] ([SurgicalCaseKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Surgical_Cases_Extended') AND name = N'IX_SurgicalCasesExtended_PatientTime')
            CREATE INDEX [IX_SurgicalCasesExtended_PatientTime] ON dbo.[tbl_FCAP1A_Surgical_Cases_Extended] ([PatientID], [SurgeryStartDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [SurgicalCaseKey] NVARCHAR(160) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [SurgicalCaseID] NVARCHAR(80) NOT NULL,
            [SurgeryStartDateTime] DATETIME2(0) NULL,
            [ScheduledDateTime] DATETIME2(0) NULL,
            [ArrivalDateTime] DATETIME2(0) NULL,
            [OperatingRoomID] NVARCHAR(80) NULL,
            [SurgicalAreaID] NVARCHAR(80) NULL,
            [CaseTypeID] NVARCHAR(80) NULL,
            [SurgeonID] NVARCHAR(100) NULL,
            [AnesthesiologistID] NVARCHAR(100) NULL,
            [AnesthesiaTypeID] NVARCHAR(80) NULL,
            [TotalDurationMinutes] INT NULL,
            [ProcedureID] NVARCHAR(100) NULL,
            [ProcedureDescription] NVARCHAR(1000) NULL,
            [ProcedureStartDateTime] DATETIME2(0) NULL,
            [ProcedureEndDateTime] DATETIME2(0) NULL,
            [ProcedureSide] NVARCHAR(60) NULL,
            [WoundClass] NVARCHAR(100) NULL,
            [ImplantCount] INT NOT NULL,
            [SchedulerNotes] NVARCHAR(2000) NULL,
            [Delayed] BIT NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        INSERT #Build ([SurgicalCaseKey], [SourceID], [PatientID], [VisitID], [SurgicalCaseID], [SurgeryStartDateTime], [ScheduledDateTime], [ArrivalDateTime], [OperatingRoomID], [SurgicalAreaID], [CaseTypeID], [SurgeonID], [AnesthesiologistID], [AnesthesiaTypeID], [TotalDurationMinutes], [ProcedureID], [ProcedureDescription], [ProcedureStartDateTime], [ProcedureEndDateTime], [ProcedureSide], [WoundClass], [ImplantCount], [SchedulerNotes], [Delayed], [RowUpdateDateTime], [ExtractedOn])
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
        FROM [NBIDRSRV2].[AKULiveATdb].[dbo].SurCase_Main s
        INNER JOIN [NBIDRSRV2].[AKULiveATdb].[dbo].CwsAppt_Main a ON a.SourceID=s.SourceID AND a.CwsApptID=s.CwsApptID
        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID=a.PatientID
        OUTER APPLY(SELECT TOP(1) p.* FROM [NBIDRSRV2].[AKULiveATdb].[dbo].SurCase_ActualProcs p
                    WHERE p.SourceID=s.SourceID AND p.CwsApptID=s.CwsApptID
                    ORDER BY CASE WHEN p.ActualProcedurePrimary IN ('Y','YES','1') THEN 0 ELSE 1 END,p.SortOrder,p.ActualProcedureUrnID) pt
        OUTER APPLY(SELECT TOP(1) x.ActualProcedureSurgeonDateTimeFromID,x.ActualProcedureSurgeonDateTimeThrough FROM [NBIDRSRV2].[AKULiveATdb].[dbo].SurCase_ActualProcSurgTimes x
                    WHERE x.SourceID=s.SourceID AND x.CwsApptID=s.CwsApptID AND x.ActualProcedureUrnID=pt.ActualProcedureUrnID
                    ORDER BY x.ActualProcedureSurgeonDateTimeFromID) st
        OUTER APPLY(SELECT COUNT_BIG(*) ImplantCount FROM [NBIDRSRV2].[AKULiveATdb].[dbo].SurCase_Implant i
                    WHERE i.SourceID=s.SourceID AND i.CwsApptID=s.CwsApptID) ic
        WHERE COALESCE(a.DateTime,s.EchartDateTime) >= @WindowStart
          AND COALESCE(a.DateTime,s.EchartDateTime) < DATEADD(DAY,1,@WindowEnd);

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_Surgical_Cases_Extended];
            INSERT INTO dbo.[tbl_FCAP1A_Surgical_Cases_Extended] ([SurgicalCaseKey], [SourceID], [PatientID], [VisitID], [SurgicalCaseID], [SurgeryStartDateTime], [ScheduledDateTime], [ArrivalDateTime], [OperatingRoomID], [SurgicalAreaID], [CaseTypeID], [SurgeonID], [AnesthesiologistID], [AnesthesiaTypeID], [TotalDurationMinutes], [ProcedureID], [ProcedureDescription], [ProcedureStartDateTime], [ProcedureEndDateTime], [ProcedureSide], [WoundClass], [ImplantCount], [SchedulerNotes], [Delayed], [RowUpdateDateTime], [ExtractedOn])
            SELECT [SurgicalCaseKey], [SourceID], [PatientID], [VisitID], [SurgicalCaseID], [SurgeryStartDateTime], [ScheduledDateTime], [ArrivalDateTime], [OperatingRoomID], [SurgicalAreaID], [CaseTypeID], [SurgeonID], [AnesthesiologistID], [AnesthesiaTypeID], [TotalDurationMinutes], [ProcedureID], [ProcedureDescription], [ProcedureStartDateTime], [ProcedureEndDateTime], [ProcedureSide], [WoundClass], [ImplantCount], [SchedulerNotes], [Delayed], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Surgical Cases',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Surgical Cases',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
