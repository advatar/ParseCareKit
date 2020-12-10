//
//  PCKVersionable.swift
//  ParseCareKit
//
//  Created by Corey Baker on 9/28/20.
//  Copyright © 2020 Network Reconnaissance Lab. All rights reserved.
//

import Foundation
import ParseSwift

internal protocol PCKVersionable: PCKObjectable, PCKSynchronizable {
    /// The UUID of the previous version of this object, or nil if there is no previous version.
    var previousVersionUUID: UUID? { get set }

    /// The previous version of this object, or nil if there is no previous version.
    var previousVersion: Self? { get set }
    
    /// The UUID of the next version of this object, or nil if there is no next version.
    var nextVersionUUID: UUID? { get set }

    /// The next version of this object, or nil if there is no next version.
    var nextVersion: Self? { get set }
    
    /// The date that this version of the object begins to take precedence over the previous version.
    /// Often this will be the same as the `createdDate`, but is not required to be.
    var effectiveDate: Date? { get set }

    /// The date on which this object was marked deleted. Note that objects are never actually deleted,
    /// but rather they are marked deleted and will no longer be returned from queries.
    var deletedDate: Date? {get set}
    
}

extension PCKVersionable {

    /// Copies the common values of another PCKVersionable object.
    /// - parameter from: The PCKVersionable object to copy from.
    mutating public func copyVersionedValues(from other: Self) {
        self.effectiveDate = other.effectiveDate
        self.deletedDate = other.deletedDate
        self.previousVersion = other.previousVersion
        self.nextVersion = other.nextVersion
        //Copy UUID's after
        self.previousVersionUUID = other.previousVersionUUID
        self.nextVersionUUID = other.nextVersionUUID
        self.copyCommonValues(from: other)
    }

    /**
     Link the versions of related objects.
     - Parameters:
        - completion: The block to execute.
     It should have the following argument signature: `(Result<Self,Error>)`.
    */
    func linkVersions(completion: @escaping (Result<Self,Error>) -> Void) {
        var versionedObject = self
        Self.first(versionedObject.previousVersionUUID, relatedObject: versionedObject.previousVersion) { result in
            
            switch result {
            
            case .success(let previousObject):
                
                versionedObject.previousVersion = previousObject
                
                Self.first(versionedObject.nextVersionUUID, relatedObject: versionedObject.nextVersion) { result in
                    
                    switch result {
                    
                    case .success(let nextObject):

                        versionedObject.nextVersion = nextObject
                        completion(.success(versionedObject))
                        
                    case .failure(_):
                        completion(.success(versionedObject))
                    }
                }
                
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /**
     Link the ParseCareKit versions of related objects. Fixex the link list between objects if they are broken.
     - Parameters:
        - versionFixed: An object that has been,
        - backwards: The direction in which the link list is being traversed. `true` is backwards, `false` is forwards.
    */
    func fixVersionLinkedList(_ versionFixed: Self, backwards:Bool){
        var versionFixed = versionFixed
        
        if backwards{
            if versionFixed.previousVersionUUID != nil && versionFixed.previousVersion == nil{
                Self.first(versionFixed.previousVersionUUID, relatedObject: versionFixed.previousVersion) { result in

                    switch result {
                    
                    case .success(var previousFound):
                        
                        versionFixed.previousVersion = previousFound
                        versionFixed.save(callbackQueue: .main) { results in
                            switch results {
                            
                            case .success(_):
                                if previousFound.nextVersion == nil{
                                    previousFound.nextVersion = versionFixed
                                    previousFound.save(callbackQueue: .main){ results in
                                        switch results {
                                        
                                        case .success(_):
                                            self.fixVersionLinkedList(previousFound, backwards: backwards)
                                        case .failure(let error):
                                            print("Couldn't save in fixVersionLinkedList(). Error: \(error). Object: \(versionFixed)")
                                        }
                                    }
                                }else{
                                    self.fixVersionLinkedList(previousFound, backwards: backwards)
                                }
                            case .failure(let error):
                                print("Couldn't save in fixVersionLinkedList(). Error: \(error). Object: \(versionFixed)")
                            }
                        }

                    case .failure(_):
                        return
                    }
                }
            }
            //We are done fixing
        }else{
            if versionFixed.nextVersionUUID != nil && versionFixed.nextVersion == nil{
                Self.first(versionFixed.nextVersionUUID, relatedObject: versionFixed.nextVersion) { result in
                    
                    switch result {
                    
                    case .success(var nextFound):
                        
                        versionFixed.nextVersion = nextFound
                        versionFixed.save(callbackQueue: .main){ results in
                            switch results {
                            
                            case .success(_):
                                if nextFound.previousVersion == nil{
                                    nextFound.previousVersion = versionFixed
                                    nextFound.save(callbackQueue: .main){ results in
                                    
                                        switch results {
                                        
                                        case .success(_):
                                            self.fixVersionLinkedList(nextFound, backwards: backwards)
                                        case .failure(let error):
                                            print("Couldn't save in fixVersionLinkedList(). Error: \(error). Object: \(versionFixed)")
                                        }
                                    }
                                }else{
                                    self.fixVersionLinkedList(nextFound, backwards: backwards)
                                }
                            case .failure(let error):
                                print("Couldn't save in fixVersionLinkedList(). Error: \(error). Object: \(versionFixed)")
                            }
                        }
                    case .failure(_):
                        return
                    }
                }
            }
            //We are done fixing
        }
    }

    /**
     Saving a `PCKVersionable` object.
     - Parameters:
        - completion: The block to execute.
     It should have the following argument signature: `(Result<PCKSynchronizable,Error>)`.
    */
    public func save(completion: @escaping(Result<PCKSynchronizable,Error>) -> Void) {
        var versionedObject = self
        _ = try? versionedObject.stampRelationalEntities()
        versionedObject.save(callbackQueue: .main){ results in
            switch results {
            
            case .success(let savedObject):
                print("Successfully added \(savedObject) to Cloud")
                
                self.linkVersions { result in
                    
                    if case let .success(modifiedObject) = result {

                        modifiedObject.save(callbackQueue: .main) { _ in }
                        
                        //Fix versioning doubly linked list if it's broken in the cloud
                        if modifiedObject.previousVersion != nil {
                            if modifiedObject.previousVersion!.nextVersion == nil {
                                modifiedObject.previousVersion!.find(modifiedObject.previousVersion!.uuid) {
                                    results in
                                    
                                    switch results {
                                    
                                    case .success(let versionedObjectsFound):
                                        guard var previousObjectFound = versionedObjectsFound.first else {
                                            return
                                        }
                                        previousObjectFound.nextVersion = modifiedObject
                                        previousObjectFound.save(callbackQueue: .main){ results in
                                            switch results {
                                                
                                            case .success(_):
                                                self.fixVersionLinkedList(previousObjectFound, backwards: true)
                                            case .failure(let error):
                                                print("Couldn't save(). Error: \(error). Object: \(self)")
                                            }
                                        }
                                    case .failure(let error):
                                        print("Couldn't find object in save(). Error: \(error). Object: \(self)")
                                    }
                                }
                            }
                        }
                        
                        if modifiedObject.nextVersion != nil {
                            if modifiedObject.nextVersion!.previousVersion == nil{
                                modifiedObject.nextVersion!.find(modifiedObject.nextVersion!.uuid) {
                                    results in
                                    
                                    switch results {
                                    
                                    case .success(let versionedObjectsFound):
                                        guard var nextObjectFound = versionedObjectsFound.first else {
                                            return
                                        }
                                        nextObjectFound.previousVersion = modifiedObject
                                        nextObjectFound.save(callbackQueue: .main){ results in
                                            switch results {
                                                
                                            case .success(_):
                                                self.fixVersionLinkedList(nextObjectFound, backwards: true)
                                            case .failure(let error):
                                                print("Couldn't save(). Error: \(error). Object: \(self)")
                                            }
                                        }
                                    case .failure(let error):
                                        print("Couldn't find object in save(). Error: \(error). Object: \(self)")
                                    }
                                }
                            }
                        }
                    }
                }
                
                completion(.success(savedObject))

            case .failure(let error):
                print("Error in \(versionedObject.className).save(). \(String(describing: error))")
                completion(.failure(error))
            }
        }
    }
}

//Fetching
extension PCKVersionable {
    private static func queryVersion(for date: Date, queryToAndWith: Query<Self>)-> Query<Self> {
        let interval = createCurrentDateInterval(for: date)
    
        let query = queryToAndWith
            .where(doesNotExist(key: kPCKObjectableDeletedDateKey)) //Only consider non deleted keys
            .where(kPCKVersionedObjectEffectiveDateKey < interval.end)
            .include([kPCKVersionedObjectNextKey, kPCKVersionedObjectPreviousKey, kPCKObjectableNotesKey])
        return query
    }
    
    private static func queryWhereNoNextVersionOrNextVersionGreaterThanEqualToDate(for date: Date)-> Query<Self> {
        
        let query = Self.query(doesNotExist(key: kPCKVersionedObjectNextKey))
            .include([kPCKVersionedObjectNextKey, kPCKVersionedObjectPreviousKey, kPCKObjectableNotesKey])
        let interval = createCurrentDateInterval(for: date)
        let greaterEqualEffectiveDate = self.query(kPCKVersionedObjectEffectiveDateKey >= interval.end)
        return Self.query(or(queries: [query,greaterEqualEffectiveDate]))
    }
    
    func find(for date: Date) throws -> [Self] {
        try Self.query(for: date).find()
    }
    
    /**
     Querying Versioned objects the same way queries are done in CareKit.
     - Parameters:
        - for: The date the object is active.
        - completion: The block to execute.
     It should have the following argument signature: `(Query<Self>)`.
    */
    //This query doesn't filter nextVersion effectiveDate >= interval.end
    public static func query(for date: Date) -> Query<Self> {
        let query = queryVersion(for: date, queryToAndWith: queryWhereNoNextVersionOrNextVersionGreaterThanEqualToDate(for: date))
            .include([kPCKVersionedObjectNextKey, kPCKVersionedObjectPreviousKey, kPCKObjectableNotesKey])
        return query
    }

    /**
     Fetch Versioned objects the same way queries are done in CareKit.
     - Parameters:
        - for: The date the objects are active.
        - completion: The block to execute.
     It should have the following argument signature: `(Result<[Self],ParseError>)`.
    */
    public func find(for date: Date, completion: @escaping(Result<[Self],ParseError>) -> Void) {
        let query = Self.query(for: date)
            .include([kPCKVersionedObjectNextKey, kPCKVersionedObjectPreviousKey, kPCKObjectableNotesKey])
        query.find(callbackQueue: .main) { results in
            switch results {
            
            case .success(let entities):
                completion(.success(entities))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

//Encodable
extension PCKVersionable {
    
    /**
     Encodes the PCKVersionable properties of the object
     - Parameters:
        - to: the encoder the properties should be encoded to.
    */
    public func encodeVersionable(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PCKCodingKeys.self)
        
        if encodingForParse {
            try container.encodeIfPresent(nextVersion, forKey: .nextVersion)
            try container.encodeIfPresent(previousVersion, forKey: .previousVersion)
            
        }
        try container.encodeIfPresent(deletedDate, forKey: .deletedDate)
        try container.encodeIfPresent(previousVersionUUID, forKey: .previousVersionUUID)
        try container.encodeIfPresent(nextVersionUUID, forKey: .nextVersionUUID)
        try container.encodeIfPresent(effectiveDate, forKey: .effectiveDate)
        try encodeObjectable(to: encoder)
    }
}