//
//  BGTaskProcessController.swift
//  BGFramework
//
//  Created by Shridhara V on 17/03/21.
//

import Foundation
import BackgroundTasks
import CoreData

protocol BGTaskProcessControllerProtocol {
    init(categories: [Constants.TaskCategory],
         registeredUsecases: [BGSyncRegistrationData],
         configuration: BGConfigurationProvider.RegistrationData,
         moc: NSManagedObjectContext,
         logger: BGLogger,
         taskData: BGTaskData)
    
    func process(completion: @escaping () -> Void)
    func stopProcessing()
}

final class BGTaskProcessController: BGTaskProcessControllerProtocol {
    
    init(categories: [Constants.TaskCategory],
         registeredUsecases: [BGSyncRegistrationData],
         configuration: BGConfigurationProvider.RegistrationData,
         moc: NSManagedObjectContext,
         logger: BGLogger,
         taskData: BGTaskData) {
        
        self.categories = categories
        self.registeredUsecases = registeredUsecases
        self.configuration = configuration
        self.moc = moc
        self.logger = logger
        self.taskData = taskData
    }
    
    private let categories: [Constants.TaskCategory]
    private let registeredUsecases: [BGSyncRegistrationData]
    private let configuration: BGConfigurationProvider.RegistrationData
    private let moc: NSManagedObjectContext
    private let logger: BGLogger
    private let taskData: BGTaskData
    
    private lazy var operationQueue: OperationQueue = {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = self.configuration.maxConcurrentSyncCount
        return operationQueue
    }()
    
    private var tasksWithPriority: [BGSyncRegistrationData] = []
    private var keyValueObs: NSKeyValueObservation?
    private var completion: (() -> Void)?
    
    private var queue = DispatchQueue(label: "com.bg.framework.task.process.controller")
}

extension BGTaskProcessController {
    func process(completion: @escaping () -> Void) {
        debugLog("Processing bagan")
        guard keyValueObs == nil else {
            //Just to make sure that this method called once.
            assertionFailure("Don't call this method more than once")
            return
        }
        
        let priorityQueue = PriorityQueue(registedItems: self.registeredUsecases, moc: self.moc)
        self.tasksWithPriority = priorityQueue.getTasks(categories: categories)
        
        guard !self.tasksWithPriority.isEmpty else {
            stopProcessing()
            completion()
            return
        }
        
        self.completion = completion
        self.keyValueObs = operationQueue.observe(\.operationCount, options: NSKeyValueObservingOptions.new) { [weak self] _, change in
            debugLog("operationCount changed: \(String(describing: change.newValue))")
            guard let safeSelf = self else {
                return
            }
            
            if safeSelf.allTheTasksCompleted() {
                debugLog("allTheTasksCompleted")
                let completion = safeSelf.completion
                safeSelf.stopProcessing() //it'll set completion nil
                completion?()
            }
        }
        
        addOperationsIfNeeded()
    }
    
    func stopProcessing() {
        debugLog("stopProcessing")
        
        self.completion = nil
        
        self.keyValueObs?.invalidate()
        
        //cancelling and suspending so that pending tasks won't resume.
        operationQueue.cancelAllOperations()
        operationQueue.isSuspended = true
    }
}

extension BGTaskProcessController {
    private func addOperationsIfNeeded() {
        queue.async { [weak self] in
            guard let safeSelf = self else {
                return
            }
            
            guard !safeSelf.tasksWithPriority.isEmpty else {
                debugLog("tasksWithPriority.isEmpty")
                return
            }
            
            while safeSelf.operationQueue.operationCount < safeSelf.configuration.maxConcurrentSyncCount {
                guard !safeSelf.tasksWithPriority.isEmpty else {
                    return
                }
                
                if let firstElement = safeSelf.tasksWithPriority.first {
                    safeSelf.tasksWithPriority.removeFirst()
                    debugLog("UsecaseSyncOperation added: \(firstElement.identifier)")
                    let operation = UsecaseSyncOperation(syncData: firstElement, moc: safeSelf.moc, logger: safeSelf.logger, taskData: safeSelf.taskData)
                    operation.completionBlock = { [weak self] in
                        self?.addOperationsIfNeeded()
                    }
                    safeSelf.operationQueue.addOperation(operation)
                }
            }
        }
    }
    
    private func allTheTasksCompleted() -> Bool {
        if tasksWithPriority.isEmpty, operationQueue.operationCount == 0 {
            return true
        }
        
        return false
    }
}