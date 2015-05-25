unit debugthread;

{$mode objfpc}{$H+}
{$INTERFACES CORBA}

interface

uses
  Classes,
  SysUtils,
  FPDbgController,
  FpDbgDwarfDataClasses,
  FpdMemoryTools,
  DbgIntfBaseTypes,
  DbgIntfDebuggerBase,
  lazCollections,
  syncobjs,
  lazfglhash,
  fpjson,
  FpDbgClasses;

type
  // The debug-thread sends three different kind of messages to it's listeners
  TFpDebugEventType = (
    etEvent,             // Messages that are send by the debugger. (debuggee has been started, pauzed, stopped, etc.)
    etLog,               // Log-messages send by the debugger. (Fpdebug also uses log-messages to inform users of some
                         // events (the dllInfo-log messages)
    etNotification       // Messages from the debug-thread itself. Including new or lost connections and commands that
                         // are queued or executed.
  );

  // The different kinds of etNotifications
  TFpDebugNotificationType = (
    ntNewConnection,
    ntLostConnection,
    ntInvalidCommand,
    ntConnectionProblem,
    ntListenerMessage,
    ntReceivedCommand,
    ntExecutedCommand,
    ntFailedCommand
  );

  // This record is used to pass debugging-events. Not every field is applicable for each type of event.
  TFpDebugEvent = record
    SendByConnectionIdentifier: integer;
    EventType: TFpDebugEventType;
    NotificationType: TFpDebugNotificationType;
    Message: string;
    EventName: string;
    LogLevel: TFPDLogLevel;
    InstructionPointerRegValue: TDBGPtr;
    AnUID: variant;
    BreakpointAddr: TDBGPtr;
    LocationRec: TDBGLocationRec;
    Validity: TDebuggerDataState;
  end;

  // Each listener should implement this interface.
  IFpDebugListener = interface ['{2230763A-672E-4EC1-941D-6B8814D789C8}']
     // This procedure is called by the debugthread when there is a message for the listener.
     // Not that this procedure will be called from within the debug-thread, and should not take too much
     // resources, or ot will slow down the debugging.
     procedure SendEvent(AnEvent: TFpDebugEvent);
     // Gives more information about the origin of the listener.
     function GetOrigin: string;
  end;

  TFpDebugThread = class;

  { TFpDebugThreadCommand }

  // The base class for all commands that can be send to the debug-thread.

  TFpDebugThreadCommand = class
  private
    FOnLog: TOnLog;
  protected
    FListenerIdentifier: integer;
    FUID: variant;
    procedure Log(const AString: string; const ALogLevel: TFPDLogLevel);
  public
    constructor Create(AListenerIdentifier: integer; AnUID: variant; AOnLog: TOnLog); virtual;
    // Descendents may override this procedure to add additionol information to the event that will
    // be send to all listeners when a command has been received succesfully
    procedure ComposeReceiveEvent(var AnEvent: TFpDebugEvent); virtual;
    // As above, for commands that has been executed successfully
    procedure ComposeSuccessEvent(var AnEvent: TFpDebugEvent); virtual;
    // As above, for commands that has failed to execute.
    procedure ComposeFailureEvent(var AnEvent: TFpDebugEvent); virtual;
    // Descendents have to override this function to implement the actual command. This function is called from within
    // the controller's debug loop. (This means it is only executed when the debuggee is paused or stopped)
    // Should return true on success, false on a failure. Set DoProcessLoop to true when the debuggee should continue,
    // make it false if the debuggee should stay in a paused state.
    function Execute(AController: TDbgController; out DoProcessLoop: boolean): boolean; virtual; abstract;
    // This method is called before the command is queued for execution in the controller's debug loop. This
    // can happen in any thread. If DoQueueCommand is true, the result is ignored or else a success-event is
    // send if the result is true, a failure if the result is false.
    function PreExecute(AController: TDbgController; out DoQueueCommand: boolean): boolean; virtual;
    // The name that is used to identify the command
    class function TextName: string; virtual; abstract;
    // The identifier of the Listener that has send this command
    property ListenerIdentifier: integer read FListenerIdentifier;
  end;
  TFpDebugThreadCommandClass = class of TFpDebugThreadCommand;
  TFpDebugThreadCommandQueue = specialize TLazThreadedQueue<TFpDebugThreadCommand>;

  { TFpDebugThread }

  TFpDebugThread = class(TThread)
  private
    FCommandQueue: TFpDebugThreadCommandQueue;
    FController: TDbgController;
    FListenerList: TThreadList;
    FMemConverter: TFpDbgMemConvertorLittleEndian;
    FMemReader: TDbgMemReader;
    FMemManager: TFpDbgMemManager;
  protected
    // Handlers for the FController-events
    procedure FControllerHitBreakpointEvent(var continue: boolean; const Breakpoint: TDbgBreakpoint);
    procedure FControllerProcessExitEvent(ExitCode: DWord);
    procedure FControllerCreateProcessEvent(var continue: boolean);
    procedure FControllerDebugInfoLoaded(Sender: TObject);
    // Main debug thread-loop
    procedure Execute; override;
    // Send an event to all listeners
    procedure SendEvent(ADebugEvent: TFpDebugEvent);
    procedure ClearEvent(var AnEvent: TFpDebugEvent);
  public
    constructor Create;
    destructor Destroy; override;
    class function Instance: TFpDebugThread;
    // Sends a command to the command-queue, the command-queue takes ownership of the command.
    procedure QueueCommand(ACommand: TFpDebugThreadCommand);
    // Procedures to send notifications and log-messages to the listeners
    procedure SendNotification(AConnectionIdentifier: integer; ANotificationType: TFpDebugNotificationType; AnUID: variant; AMessage, ACommand: string);
    procedure SendNotification(AConnectionIdentifier: integer; ANotificationType: TFpDebugNotificationType; AnUID: variant; AMessage, ACommand: string; Arg: array of const); overload;
    procedure SendLogMessage(const AString: string; const ALogLevel: TFPDLogLevel);
    // Methods to add and remove listeners
    function AddListener(AFpDebugListener: IFpDebugListener): integer;
    procedure RemoveListener(AFpDebugListener: IFpDebugListener);
  end;

const
  FpEventTypeNames: array[TFpDebugEventType] of string = (
    'event',
    'log',
    'notification');
  FpDebugNotificationTypeNames: array[TFpDebugNotificationType] of string = (
    'NewConnection',
    'LostConnection',
    'InvalidCommand',
    'ConnectionProblem',
    'ListenerMessage',
    'ReceivedCommand',
    'ExecutedCommand',
    'FailedCommand');


implementation

var
  FFpDebugThread: TFpDebugThread;

type

  { TFpDbgMemReader }

  TFpDbgMemReader = class(TDbgMemReader)
    private
      FDebugThread: TFpDebugThread;
    protected
      function GetDbgProcess: TDbgProcess; override;
    public
      constructor create(ADebugThread: TFpDebugThread);
  end;

{ TFpDbgMemReader }

function TFpDbgMemReader.GetDbgProcess: TDbgProcess;
begin
  result := FDebugThread.FController.CurrentProcess;
end;

constructor TFpDbgMemReader.create(ADebugThread: TFpDebugThread);
begin
  Inherited Create;
  FDebugThread:=ADebugThread;
end;

{ TFpDebugThreadCommand }

procedure TFpDebugThreadCommand.Log(const AString: string; const ALogLevel: TFPDLogLevel);
begin
  if assigned(FOnLog) then
    FOnLog(AString, ALogLevel);
end;

constructor TFpDebugThreadCommand.Create(AListenerIdentifier: integer;
  AnUID: variant; AOnLog: TOnLog);
begin
  FListenerIdentifier:=AListenerIdentifier;
  FUID:=AnUID;
  FOnLog:=AOnLog;
end;

procedure TFpDebugThreadCommand.ComposeReceiveEvent(var AnEvent: TFpDebugEvent);
begin
  AnEvent.EventType:=etNotification;
  AnEvent.NotificationType:=ntReceivedCommand;
  AnEvent.SendByConnectionIdentifier:=ListenerIdentifier;
  AnEvent.AnUID:=FUID;
  AnEvent.EventName:=TextName;
  AnEvent.Message:=Format('Received %s-command.',[TextName]);
end;

procedure TFpDebugThreadCommand.ComposeSuccessEvent(var AnEvent: TFpDebugEvent);
begin
  AnEvent.EventType:=etNotification;
  AnEvent.NotificationType:=ntExecutedCommand;
  AnEvent.SendByConnectionIdentifier:=ListenerIdentifier;
  AnEvent.AnUID:=FUID;
  AnEvent.EventName:=TextName;
  AnEvent.Message:=Format('%s-command executed succesfully.',[TextName]);
end;

procedure TFpDebugThreadCommand.ComposeFailureEvent(var AnEvent: TFpDebugEvent);
begin
  AnEvent.EventType:=etNotification;
  AnEvent.NotificationType:=ntFailedCommand;
  AnEvent.SendByConnectionIdentifier:=ListenerIdentifier;
  AnEvent.AnUID:=FUID;
  AnEvent.EventName:=TextName;
  AnEvent.Message:=Format('%s-command failed.',[TextName]);
end;

function TFpDebugThreadCommand.PreExecute(AController: TDbgController; out DoQueueCommand: boolean): boolean;
begin
  DoQueueCommand:=true;
  result:=true;
end;

{ TFpDebugThread }

procedure TFpDebugThread.SendLogMessage(const AString: string; const ALogLevel: TFPDLogLevel);
var
  ADebugEvent: TFpDebugEvent;
begin
  ClearEvent(ADebugEvent);
  ADebugEvent.EventType:=etLog;
  ADebugEvent.Message:=AString;
  ADebugEvent.LogLevel:=ALogLevel;

  SendEvent(ADebugEvent);
end;

procedure TFpDebugThread.ClearEvent(var AnEvent: TFpDebugEvent);
begin
  AnEvent.AnUID:=null;
  AnEvent.SendByConnectionIdentifier:=-1;
  AnEvent.InstructionPointerRegValue:=0;
  AnEvent.BreakpointAddr:=0;
  AnEvent.LocationRec.Address:=0;
  AnEvent.Validity:=ddsUnknown;
end;

procedure TFpDebugThread.FControllerDebugInfoLoaded(Sender: TObject);
begin
  TFpDwarfInfo(FController.CurrentProcess.DbgInfo).MemManager := FMemManager;
end;

procedure TFpDebugThread.FControllerHitBreakpointEvent(var continue: boolean; const Breakpoint: TDbgBreakpoint);
var
  ADebugEvent: TFpDebugEvent;
begin
  ClearEvent(ADebugEvent);
  ADebugEvent.EventType:=etEvent;
  ADebugEvent.EventName:='BreakPoint';
  ADebugEvent.InstructionPointerRegValue:=FController.CurrentProcess.GetInstructionPointerRegisterValue;
  if assigned(Breakpoint) then
    ADebugEvent.BreakpointAddr:=Breakpoint.Location;

  SendEvent(ADebugEvent);
  continue:=false;
end;

procedure TFpDebugThread.FControllerProcessExitEvent(ExitCode: DWord);
var
  ADebugEvent: TFpDebugEvent;
begin
  ClearEvent(ADebugEvent);
  ADebugEvent.EventType:=etEvent;
  ADebugEvent.EventName:='ExitProcess';
  ADebugEvent.InstructionPointerRegValue:=FController.CurrentProcess.GetInstructionPointerRegisterValue;

  SendEvent(ADebugEvent);
end;

procedure TFpDebugThread.FControllerCreateProcessEvent(var continue: boolean);
var
  ADebugEvent: TFpDebugEvent;
begin
  ClearEvent(ADebugEvent);
  ADebugEvent.EventType:=etEvent;
  ADebugEvent.EventName:='CreateProcess';
  ADebugEvent.InstructionPointerRegValue:=FController.CurrentProcess.GetInstructionPointerRegisterValue;

  SendEvent(ADebugEvent);
  continue:=false;
end;

procedure TFpDebugThread.Execute;
var
  ACommand: TFpDebugThreadCommand;
  ARunLoop: boolean;
  AnEvent: TFpDebugEvent;
begin
  FController := TDbgController.Create;
  FController.OnCreateProcessEvent:=@FControllerCreateProcessEvent;
  FController.OnProcessExitEvent:=@FControllerProcessExitEvent;
  FController.OnHitBreakpointEvent:=@FControllerHitBreakpointEvent;
  FController.OnDebugInfoLoaded:=@FControllerDebugInfoLoaded;
  FController.OnLog:=@SendLogMessage;

  try
    repeat
    try
      if FCommandQueue.PopItem(ACommand)<>wrSignaled then
        ACommand:=nil;

      if assigned(ACommand) then
        begin
        try
          ClearEvent(AnEvent);
          ACommand.ComposeReceiveEvent(AnEvent);
          SendEvent(AnEvent);
          if ACommand.Execute(FController, ARunLoop) then
            begin
            ClearEvent(AnEvent);
            ACommand.ComposeSuccessEvent(AnEvent);
            SendEvent(AnEvent);
            end
          else
            begin
            ClearEvent(AnEvent);
            ACommand.ComposeFailureEvent(AnEvent);
            SendEvent(AnEvent);
            end;
        finally
          ACommand.Free;
        end;

        while ARunLoop do
          begin
          FController.ProcessLoop;
          FController.SendEvents(ARunLoop);
          end;
        end;
    except
      on E: Exception do
        writeln('Exception in debug-thread: '+e.Message); // just continue
    end;
    until terminated;

  finally
    FController.Free;
  end;
end;

procedure TFpDebugThread.SendEvent(ADebugEvent: TFpDebugEvent);
var
  i: integer;
  AList: TList;
begin
  AList:=FListenerList.LockList;
  try
    for i := 0 to AList.Count-1 do
      begin
      IFpDebugListener(AList[i]).SendEvent(ADebugEvent);
      end;
  finally
    FListenerList.UnlockList;
  end;
end;

constructor TFpDebugThread.Create;
begin
  inherited create(false);
  FCommandQueue := TFpDebugThreadCommandQueue.create(100, INFINITE, 100);
  FListenerList:=TThreadList.Create;

  FMemReader := TFpDbgMemReader.Create(self);
  FMemConverter := TFpDbgMemConvertorLittleEndian.Create;
  FMemManager := TFpDbgMemManager.Create(FMemReader, FMemConverter);
end;

destructor TFpDebugThread.Destroy;
begin
  FListenerList.Free;
  FCommandQueue.Free;
  inherited Destroy;
  FMemManager.Free;
  FMemConverter.Free;
  FMemReader.Free;
end;

class function TFpDebugThread.Instance: TFpDebugThread;
begin
  if not assigned(FFpDebugThread) then
    FFpDebugThread:=TFpDebugThread.Create;
  result := FFpDebugThread;
end;

procedure TFpDebugThread.QueueCommand(ACommand: TFpDebugThreadCommand);
var
  DoQueueCommand: boolean;
  Success: boolean;
  AnEvent: TFpDebugEvent;
begin
  try
    Success := ACommand.PreExecute(FController, DoQueueCommand);
  except
    on E: Exception do
      begin
      SendLogMessage('Exception while executing command :'+e.Message, dllError);
      DoQueueCommand:=false;
      Success:=false;
      end;
  end;
  if DoQueueCommand then
    begin
    FCommandQueue.PushItem(ACommand);
    end
  else
    begin
    try
      if Success then
        begin
        ClearEvent(AnEvent);
        ACommand.ComposeSuccessEvent(AnEvent);
        SendEvent(AnEvent);
        end
      else
        begin
        ClearEvent(AnEvent);
        ACommand.ComposeFailureEvent(AnEvent);
        SendEvent(AnEvent);
        end;
    finally
      ACommand.Free;
    end;
    end;
end;

procedure TFpDebugThread.SendNotification(AConnectionIdentifier: integer; ANotificationType: TFpDebugNotificationType; AnUID: variant; AMessage, ACommand: string);
var
  AnEvent: TFpDebugEvent;
begin
  ClearEvent(AnEvent);
  AnEvent.SendByConnectionIdentifier:=AConnectionIdentifier;
  AnEvent.EventType:=etNotification;
  AnEvent.NotificationType:=ANotificationType;
  anEvent.EventName:=ACommand;
  AnEvent.Message:=AMessage;
  AnEvent.AnUID:=AnUID;
  SendEvent(AnEvent);
end;

procedure TFpDebugThread.SendNotification(AConnectionIdentifier: integer; ANotificationType: TFpDebugNotificationType; AnUID: variant; AMessage, ACommand: string;
  Arg: array of const);
begin
  SendNotification(AConnectionIdentifier, ANotificationType, AnUID, format(AMessage, Arg), ACommand);
end;

var
  GIdentifierCount: integer = 0;

function TFpDebugThread.AddListener(AFpDebugListener: IFpDebugListener): integer;
begin
  inc(GIdentifierCount);
  result := GIdentifierCount;
  SendNotification(result, ntNewConnection, null, 'New connection from %s', '',[AFpDebugListener.GetOrigin]);
  FListenerList.Add(AFpDebugListener);
end;

procedure TFpDebugThread.RemoveListener(AFpDebugListener: IFpDebugListener);
begin
  FListenerList.Remove(AFpDebugListener);
end;

initialization
  FFpDebugThread := nil;
finalization
  FFpDebugThread.Free;
end.

