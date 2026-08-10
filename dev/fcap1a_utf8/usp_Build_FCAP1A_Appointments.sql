USE [CDIO_MeditechDB]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Procedure : dbo.usp_Build_FCAP1A_Appointments
    Purpose   : Builds appointment occurrences with status, arrival, comments, resources, participants, and audit history.
    Grain     : one row per scheduled appointment occurrence
    Author    : test
    Safety    : staged build, minimum-row gate, transactional publication, run logging.
*/
CREATE OR ALTER PROCEDURE dbo.[usp_Build_FCAP1A_Appointments]
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

    IF OBJECT_ID(N'dbo.tbl_FCAP1A_Appointments', N'U') IS NULL
    BEGIN
        CREATE TABLE dbo.[tbl_FCAP1A_Appointments] (
            [AppointmentKey] NVARCHAR(160) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [AppointmentID] NVARCHAR(80) NOT NULL,
            [AppointmentDateTime] DATETIME2(0) NULL,
            [ArrivalDateTime] DATETIME2(0) NULL,
            [ReservationDateTime] DATETIME2(0) NULL,
            [DurationMinutes] INT NULL,
            [OriginalDurationMinutes] INT NULL,
            [StatusID] NVARCHAR(80) NULL,
            [AppointmentType] NVARCHAR(100) NULL,
            [ProcedureID] NVARCHAR(80) NULL,
            [Reason] NVARCHAR(1000) NULL,
            [ProviderID] NVARCHAR(100) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [LocationID] NVARCHAR(60) NULL,
            [ConfirmationNumber] NVARCHAR(100) NULL,
            [ReservationComment] NVARCHAR(2000) NULL,
            [AppointmentComment] NVARCHAR(MAX) NULL,
            [ResourceCount] INT NOT NULL,
            [ParticipantCount] INT NOT NULL,
            [LastAuditDateTime] DATETIME2(0) NULL,
            [LastAuditType] NVARCHAR(100) NULL,
            [ExternalSource] NVARCHAR(100) NULL,
            [VideoVisitIdentifier] NVARCHAR(200) NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Appointments') AND name = N'UX_Appointments_Key')
        CREATE UNIQUE INDEX [UX_Appointments_Key] ON dbo.[tbl_FCAP1A_Appointments] ([AppointmentKey]);
        IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'dbo.tbl_FCAP1A_Appointments') AND name = N'IX_Appointments_PatientTime')
            CREATE INDEX [IX_Appointments_PatientTime] ON dbo.[tbl_FCAP1A_Appointments] ([PatientID], [AppointmentDateTime]);

    BEGIN TRY
        CREATE TABLE #Build (
            [AppointmentKey] NVARCHAR(160) NOT NULL,
            [SourceID] VARCHAR(3) NULL,
            [PatientID] NVARCHAR(50) NOT NULL,
            [VisitID] NVARCHAR(50) NULL,
            [AppointmentID] NVARCHAR(80) NOT NULL,
            [AppointmentDateTime] DATETIME2(0) NULL,
            [ArrivalDateTime] DATETIME2(0) NULL,
            [ReservationDateTime] DATETIME2(0) NULL,
            [DurationMinutes] INT NULL,
            [OriginalDurationMinutes] INT NULL,
            [StatusID] NVARCHAR(80) NULL,
            [AppointmentType] NVARCHAR(100) NULL,
            [ProcedureID] NVARCHAR(80) NULL,
            [Reason] NVARCHAR(1000) NULL,
            [ProviderID] NVARCHAR(100) NULL,
            [FacilityID] NVARCHAR(60) NULL,
            [LocationID] NVARCHAR(60) NULL,
            [ConfirmationNumber] NVARCHAR(100) NULL,
            [ReservationComment] NVARCHAR(2000) NULL,
            [AppointmentComment] NVARCHAR(MAX) NULL,
            [ResourceCount] INT NOT NULL,
            [ParticipantCount] INT NOT NULL,
            [LastAuditDateTime] DATETIME2(0) NULL,
            [LastAuditType] NVARCHAR(100) NULL,
            [ExternalSource] NVARCHAR(100) NULL,
            [VideoVisitIdentifier] NVARCHAR(200) NULL,
            [RowUpdateDateTime] DATETIME2(0) NULL,
            [ExtractedOn] DATETIME2(0) NOT NULL
        );

        SELECT @TotalEligible = COUNT_BIG(*) FROM dbo.tbl_FCAP1A_Cohort10_Extended;

        INSERT #Build ([AppointmentKey], [SourceID], [PatientID], [VisitID], [AppointmentID], [AppointmentDateTime], [ArrivalDateTime], [ReservationDateTime], [DurationMinutes], [OriginalDurationMinutes], [StatusID], [AppointmentType], [ProcedureID], [Reason], [ProviderID], [FacilityID], [LocationID], [ConfirmationNumber], [ReservationComment], [AppointmentComment], [ResourceCount], [ParticipantCount], [LastAuditDateTime], [LastAuditType], [ExternalSource], [VideoVisitIdentifier], [RowUpdateDateTime], [ExtractedOn])
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
        FROM [NBIDRSRV2].[AKULiveATdb].[dbo].CwsAppt_Main a
        INNER JOIN dbo.tbl_FCAP1A_Cohort10_Extended c ON c.PatientID = a.PatientID
        OUTER APPLY (SELECT COUNT_BIG(*) AS ResourceCount FROM [NBIDRSRV2].[AKULiveATdb].[dbo].CwsAppt_Resources x
                     WHERE x.SourceID = a.SourceID AND x.CwsApptID = a.CwsApptID) rc
        OUTER APPLY (SELECT TOP (1) x.AuditDateTime, x.AuditType FROM [NBIDRSRV2].[AKULiveATdb].[dbo].CwsAppt_AuditTrail x
                     WHERE x.SourceID = a.SourceID AND x.CwsApptID = a.CwsApptID ORDER BY x.AuditDateTime DESC, x.AuditUrnID DESC) au
        WHERE a.DateTime >= @WindowStart AND a.DateTime < DATEADD(DAY, 1, @WindowEnd);

        SELECT @RecordCount = COUNT_BIG(*) FROM #Build;
        IF @RecordCount < @MinimumPublishRows
            THROW 51001, 'Candidate output is empty or below MinimumPublishRows; existing publication was preserved.', 1;

        BEGIN TRANSACTION;
            TRUNCATE TABLE dbo.[tbl_FCAP1A_Appointments];
            INSERT INTO dbo.[tbl_FCAP1A_Appointments] ([AppointmentKey], [SourceID], [PatientID], [VisitID], [AppointmentID], [AppointmentDateTime], [ArrivalDateTime], [ReservationDateTime], [DurationMinutes], [OriginalDurationMinutes], [StatusID], [AppointmentType], [ProcedureID], [Reason], [ProviderID], [FacilityID], [LocationID], [ConfirmationNumber], [ReservationComment], [AppointmentComment], [ResourceCount], [ParticipantCount], [LastAuditDateTime], [LastAuditType], [ExternalSource], [VideoVisitIdentifier], [RowUpdateDateTime], [ExtractedOn])
            SELECT [AppointmentKey], [SourceID], [PatientID], [VisitID], [AppointmentID], [AppointmentDateTime], [ArrivalDateTime], [ReservationDateTime], [DurationMinutes], [OriginalDurationMinutes], [StatusID], [AppointmentType], [ProcedureID], [Reason], [ProviderID], [FacilityID], [LocationID], [ConfirmationNumber], [ReservationComment], [AppointmentComment], [ResourceCount], [ParticipantCount], [LastAuditDateTime], [LastAuditType], [ExternalSource], [VideoVisitIdentifier], [RowUpdateDateTime], [ExtractedOn] FROM #Build;
        COMMIT TRANSACTION;

        SET @RunEnd = SYSDATETIME();
        INSERT dbo.FCAP1A_Cohort_Log
            (RunStart, RunEnd, DurationSeconds, RunStatus, DataTopic, WindowStart, WindowEnd,
             TotalEligible, RecordCount, ProcessedBy, Remarks)
        VALUES
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'SUCCESS', N'Appointments',
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
            (@RunStart, @RunEnd, DATEDIFF(SECOND, @RunStart, @RunEnd), 'FAILED', N'Appointments',
             @WindowStart, @WindowEnd, CONVERT(INT, IIF(@TotalEligible > 2147483647, 2147483647, @TotalEligible)),
             CONVERT(INT, IIF(@RecordCount > 2147483647, 2147483647, @RecordCount)), SYSTEM_USER,
             ERROR_MESSAGE(), N'Existing output retained when failure occurred before publication.');
        THROW;
    END CATCH;
END;
GO
